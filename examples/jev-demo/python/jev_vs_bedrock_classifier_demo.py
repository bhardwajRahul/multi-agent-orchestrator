"""
Side-by-side classifier comparison: JevClassifier vs BedrockClassifier.

Runs the same scripted multi-turn conversation through both classifiers.
The conversation deliberately interleaves agents: an agent proposes
something, the user switches to another domain, and only answers the
pending proposal ("yes, please go ahead") one or two turns later. Routing
those answers correctly requires understanding which question is still
open in the history - "same agent as the last turn" gives the wrong answer.

Run from this directory (examples/jev-demo/python), after
`pip install -r requirements.txt`:
  export TYPESAFE_API_KEY=...
  # plus AWS credentials with bedrock:InvokeModel access (AWS_PROFILE/AWS_REGION)
  python jev_vs_bedrock_classifier_demo.py

At the end it prints accuracy, latency and cost for each classifier and the
relative difference. Both costs are estimated from token counts:
  - Jev:     JEV_USD_PER_MTOK per million input tokens, output free
             (defaults to the official $0.042 rate, https://docs.typesafe.ai/models)
  - Bedrock: BEDROCK_INPUT_USD_PER_MTOK / BEDROCK_OUTPUT_USD_PER_MTOK
             (defaults below), since the Converse API reports tokens, not dollars.
"""

import asyncio
import os
import sys
import time
from dataclasses import dataclass
from typing import Any, Callable, Optional

from agent_squad.agents import Agent, AgentOptions
from agent_squad.classifiers import (
    BedrockClassifier,
    BedrockClassifierOptions,
    Classifier,
    JevClassifier,
    JevClassifierOptions,
)
from agent_squad.types import ConversationMessage, ParticipantRole

BEDROCK_CLASSIFIER_MODEL_ID = os.environ.get("BEDROCK_CLASSIFIER_MODEL_ID", "us.anthropic.claude-opus-5")

# Estimated Bedrock pricing for the model above, in USD per million tokens.
# Override with env vars if your account's rate differs.
BEDROCK_INPUT_USD_PER_MTOK = float(os.environ.get("BEDROCK_INPUT_USD_PER_MTOK", 5))
BEDROCK_OUTPUT_USD_PER_MTOK = float(os.environ.get("BEDROCK_OUTPUT_USD_PER_MTOK", 25))

# Official Jev 1.13 pricing: $0.042 per million input tokens, output tokens
# free (https://docs.typesafe.ai/models). Override if you call Jev through a
# gateway with its own rate.
JEV_USD_PER_MILLION_INPUT_TOKENS = float(os.environ.get("JEV_USD_PER_MTOK", 0.042))


class DomainAgent(Agent):
    """Minimal agent stub: only id/name/description matter for classification."""

    async def process_request(self, *args: Any, **kwargs: Any) -> ConversationMessage:
        raise NotImplementedError("This demo never invokes the agents themselves")


agents = [
    DomainAgent(AgentOptions(
        name="Tech Support Agent",
        description="Troubleshoots devices, software errors, crashes, login and password problems, "
                    "Wi-Fi and connectivity issues, installations, and account access.",
    )),
    DomainAgent(AgentOptions(
        name="Billing Agent",
        description="Handles invoices, duplicate or unexpected charges, refunds, payment methods, "
                    "subscription plans, upgrades, downgrades, and cancellations.",
    )),
    DomainAgent(AgentOptions(
        name="Travel Agent",
        description="Plans and changes trips: flights, hotels, itineraries, baggage rules, "
                    "visas and entry requirements, seat selection, and travel insurance.",
    )),
    DomainAgent(AgentOptions(
        name="Wellness Agent",
        description="Advises on nutrition, meal planning, exercise routines, sleep quality, "
                    "hydration, stress management, and general healthy-habit questions.",
    )),
]

agents_by_id = {agent.id: agent for agent in agents}


class MeteredBedrockClassifier(BedrockClassifier):
    """BedrockClassifier does not expose token usage, so this subclass captures
    it from the parsed Converse response via a botocore event hook."""

    def __init__(self, options: BedrockClassifierOptions):
        super().__init__(options)
        self.last_usage: Optional[dict[str, Any]] = None
        self.client.meta.events.register("after-call.bedrock-runtime.Converse", self._capture_usage)

    def _capture_usage(self, parsed: Optional[dict[str, Any]] = None, **_: Any) -> None:
        usage = (parsed or {}).get("usage")
        if usage:
            self.last_usage = usage


# The scripted conversation. Each turn is classified against the history of
# all previous turns; the canned agent reply (with the [Agent Name] prefix,
# as an orchestrator would store it) is appended afterwards so follow-ups
# and context switches have real history to route against.
@dataclass
class Turn:
    user: str
    expected: str  # agent id
    reply: str


conversation = [
    # Billing proposes an action and leaves the question open.
    Turn(
        user="I was charged twice for my subscription this month",
        expected="billing-agent",
        reply="[Billing Agent] I can open a refund request for the duplicate charge right away - "
              "it takes 3-5 business days to land. Shall I proceed?",
    ),
    # The user switches to tech support before answering. The tech reply is
    # deliberately a statement, so billing's proposal stays the only open question.
    Turn(
        user="hold on - my laptop won't connect to the office Wi-Fi anymore",
        expected="tech-support-agent",
        reply="[Tech Support Agent] Restart the laptop, then forget and rejoin the network. "
              "If it still fails, update the Wi-Fi driver from the manufacturer's site.",
    ),
    # Interleaved follow-up: this answers billing's proposal from two turns
    # ago, not the tech support turn right before it.
    Turn(
        user="yes, please go ahead",
        expected="billing-agent",
        reply="[Billing Agent] Done, the refund request is submitted; you'll get a confirmation "
              "email shortly.",
    ),
    # Back to tech support; its reply ends with a pending offer.
    Turn(
        user="the wifi is still not working after doing all that",
        expected="tech-support-agent",
        reply="[Tech Support Agent] Then set your DNS to 1.1.1.1 and try again. I can also walk "
              "you through checking the adapter logs - want me to?",
    ),
    # Travel interleaves, leaving a second pending question (which airline).
    Turn(
        user="How many bags can I check on a flight to Tokyo?",
        expected="travel-agent",
        reply="[Travel Agent] Most airlines include one 23 kg checked bag to Tokyo in economy; "
              "a second bag is usually 75-100 USD. Which airline are you flying?",
    ),
    # Two questions are pending (tech's offer, travel's airline). This one
    # answers tech support's "walk you through" offer from two turns ago.
    Turn(
        user="yes, walk me through it",
        expected="tech-support-agent",
        reply="[Tech Support Agent] Open the system's network logs and look for adapter resets "
              "or DHCP errors; tell me what you find.",
    ),
    # And this one answers travel's "which airline" question from turn 5.
    Turn(
        user="it's ANA",
        expected="travel-agent",
        reply="[Travel Agent] ANA includes two 23 kg checked bags on international routes, so "
              "you're covered without extra fees.",
    ),
    # A fresh domain; wellness leaves an offer open ("more options?").
    Turn(
        user="what should I eat before an early morning workout?",
        expected="wellness-agent",
        reply="[Wellness Agent] Something light and carb-forward 30-60 minutes before: a banana, "
              "toast with honey, or a small bowl of oatmeal. Want a few more options?",
    ),
    # Billing interleaves again with a direct question; the reply is a
    # statement, so wellness's offer stays the only open question.
    Turn(
        user="did the refund confirmation email go out yet?",
        expected="billing-agent",
        reply="[Billing Agent] Yes, it was sent a few minutes ago - check your spam folder if "
              "you don't see it.",
    ),
    # Answers wellness's "more options?" offer from two turns ago.
    Turn(
        user="yes, a couple more please",
        expected="wellness-agent",
        reply="[Wellness Agent] Dates with peanut butter, a rice cake with jam, or half a bagel. "
              "Should I put together a weekly pre-workout meal plan for you?",
    ),
    # Travel interleaves with a visa question; again answered with a statement.
    Turn(
        user="one more thing - do I need a visa for Japan as a French citizen?",
        expected="travel-agent",
        reply="[Travel Agent] No - French citizens can stay in Japan visa-free for up to 90 days "
              "for tourism.",
    ),
    # Closes wellness's pending meal-plan offer from two turns ago.
    Turn(
        user="ok, put it together for me",
        expected="wellness-agent",
        reply="[Wellness Agent] Done - a 7-day pre-workout meal plan alternating oatmeal and "
              "toast days, around 250 kcal each, is on its way.",
    ),
]


@dataclass
class TurnResult:
    agent_id: str  # "(unknown)" when no agent matched, "(error: ...)" on failure
    confidence: float
    latency_ms: float
    cost_usd: float
    correct: bool


def format_usd(value: float) -> str:
    return "$" + f"{value:.8f}".rstrip("0").rstrip(".")


async def classify_timed(classifier: Classifier,
                         user_input: str,
                         history: list[ConversationMessage],
                         expected: str,
                         cost_of_last_call: Callable[[], float]) -> TurnResult:
    start = time.perf_counter()
    try:
        result = await classifier.classify(user_input, history)
        latency_ms = (time.perf_counter() - start) * 1000
        agent_id = result.selected_agent.id if result.selected_agent else "(unknown)"
        return TurnResult(agent_id, result.confidence, latency_ms, cost_of_last_call(), agent_id == expected)
    except Exception as error:
        return TurnResult(f"(error: {error})", 0.0, (time.perf_counter() - start) * 1000, 0.0, False)


def print_turn_line(label: str, r: TurnResult) -> None:
    print(
        f"  {label:<8}: {r.agent_id:<20} conf {r.confidence:.2f}  "
        f"{round(r.latency_ms):>5}ms  "
        f"{format_usd(r.cost_usd):<11} {'OK' if r.correct else 'MISS'}"
    )


def summarize(label: str, results: list[TurnResult]) -> None:
    correct = sum(r.correct for r in results)
    total_ms = sum(r.latency_ms for r in results)
    total_usd = sum(r.cost_usd for r in results)
    print(
        f"  {label:<8}: {correct}/{len(results)} correct   "
        f"avg {round(total_ms / len(results)):>5}ms   "
        f"total {round(total_ms):>6}ms   "
        f"cost {format_usd(total_usd)}"
    )


async def main() -> None:
    jev = JevClassifier(JevClassifierOptions(base_url=os.environ.get("JEV_API_URL")))
    jev.set_agents(agents_by_id)

    bedrock = MeteredBedrockClassifier(BedrockClassifierOptions(
        model_id=BEDROCK_CLASSIFIER_MODEL_ID,
        region=os.environ.get("AWS_REGION") or os.environ.get("REGION"),
    ))
    bedrock.set_agents(agents_by_id)

    print(f"Jev model:     jev-latest ({os.environ.get('JEV_API_URL', 'default endpoint')})")
    print(f"Bedrock model: {BEDROCK_CLASSIFIER_MODEL_ID}\n")

    def jev_cost() -> float:
        tokens = (jev.get_last_usage() or {}).get("input_tokens", 0)
        return tokens * JEV_USD_PER_MILLION_INPUT_TOKENS / 1_000_000

    def bedrock_cost() -> float:
        usage = bedrock.last_usage or {}
        return (
            usage.get("inputTokens", 0) * BEDROCK_INPUT_USD_PER_MTOK / 1_000_000
            + usage.get("outputTokens", 0) * BEDROCK_OUTPUT_USD_PER_MTOK / 1_000_000
        )

    history: list[ConversationMessage] = []
    jev_results: list[TurnResult] = []
    bedrock_results: list[TurnResult] = []

    for index, turn in enumerate(conversation, start=1):
        print(f'Turn {index}/{len(conversation)} > "{turn.user}"')
        print(f"  expected: {turn.expected}")

        # Same input, same history, for both classifiers.
        jev_result = await classify_timed(jev, turn.user, history, turn.expected, jev_cost)
        bedrock_result = await classify_timed(bedrock, turn.user, history, turn.expected, bedrock_cost)

        print_turn_line("jev", jev_result)
        print_turn_line("bedrock", bedrock_result)
        print()

        jev_results.append(jev_result)
        bedrock_results.append(bedrock_result)

        # Advance the shared conversation with the scripted agent reply.
        history.extend([
            ConversationMessage(role=ParticipantRole.USER.value, content=[{"text": turn.user}]),
            ConversationMessage(role=ParticipantRole.ASSISTANT.value, content=[{"text": turn.reply}]),
        ])

    print(f"=== Summary ({len(conversation)} turns) ===")
    summarize("jev", jev_results)
    summarize("bedrock", bedrock_results)

    jev_avg_ms = sum(r.latency_ms for r in jev_results) / len(jev_results)
    bedrock_avg_ms = sum(r.latency_ms for r in bedrock_results) / len(bedrock_results)
    jev_total_cost = sum(r.cost_usd for r in jev_results)
    bedrock_total_cost = sum(r.cost_usd for r in bedrock_results)

    print()
    if jev_avg_ms > 0 and bedrock_avg_ms > 0:
        fast, slow, ratio = (
            ("jev", "bedrock", bedrock_avg_ms / jev_avg_ms) if jev_avg_ms <= bedrock_avg_ms
            else ("bedrock", "jev", jev_avg_ms / bedrock_avg_ms)
        )
        print(f"Latency: {fast} was {ratio:.1f}x faster than {slow} on average.")
    if jev_total_cost > 0 and bedrock_total_cost > 0:
        cheap, dear, ratio = (
            ("jev", "bedrock", bedrock_total_cost / jev_total_cost) if jev_total_cost <= bedrock_total_cost
            else ("bedrock", "jev", jev_total_cost / bedrock_total_cost)
        )
        print(f"Cost:    {cheap} was {ratio:.1f}x cheaper than {dear} (both estimated from token counts).")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as error:
        print(f"FAILED: {error}", file=sys.stderr)
        sys.exit(1)
