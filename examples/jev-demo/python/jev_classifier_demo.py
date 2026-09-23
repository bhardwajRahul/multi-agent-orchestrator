"""
JevClassifier demo: routing across four unrelated domains, with real agent
responses from Amazon Bedrock so multi-turn conversations can be tested.

Run from this directory (examples/jev-demo/python), after
`pip install -r requirements.txt`:
  export TYPESAFE_API_KEY=...
  # plus AWS credentials with bedrock:InvokeModel access (AWS_PROFILE/AWS_REGION)
  python jev_classifier_demo.py                # scripted queries
  python jev_classifier_demo.py --interactive  # type your own

The classifier only needs the Jev key; the agents call Bedrock (Claude
Sonnet 5 by default, override with BEDROCK_MODEL_ID) to answer once a turn
has been routed. Scripted mode never calls Bedrock, only the classifier.
"""

import asyncio
import json
import os
import sys
from typing import Any, Optional

from agent_squad.agents import BedrockLLMAgent, BedrockLLMAgentOptions
from agent_squad.classifiers import JevClassifier, JevClassifierOptions
from agent_squad.types import ConversationMessage, ParticipantRole

# Official Jev 1.13 pricing: $0.042 per million input tokens, output tokens
# free (https://docs.typesafe.ai/models). The API reports token counts, not
# dollars, so the cost is estimated. Override JEV_USD_PER_MTOK if you call
# Jev through a gateway with its own rate.
JEV_USD_PER_MILLION_INPUT_TOKENS = float(os.environ.get("JEV_USD_PER_MTOK", 0.042))


def domain_agent(name: str, description: str, role: str) -> BedrockLLMAgent:
    """Real Bedrock-backed agent. Answers are kept short and end with a
    follow-up question, so the conversation history gives the classifier
    something to route short replies like "yes" or "tell me more" against."""
    return BedrockLLMAgent(BedrockLLMAgentOptions(
        name=name,
        description=description,
        model_id=os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-sonnet-5"),
        # boto3 only reads AWS_DEFAULT_REGION on its own, so pass AWS_REGION through.
        region=os.environ.get("AWS_REGION"),
        # Claude Opus 5 / Sonnet 5 reject sampling parameters, so drop the SDK's
        # temperature/topP defaults.
        inference_config={"maxTokens": 1024, "temperature": None, "topP": None},
        custom_system_prompt={
            "template": (
                f"You are {role} Answer in 2-4 sentences, and when a natural next step "
                "exists, end with a short follow-up question offering it."
            ),
        },
    ))


agents = [
    domain_agent(
        "Tech Support Agent",
        "Troubleshoots devices, software errors, crashes, login and password problems, "
        "Wi-Fi and connectivity issues, installations, and account access.",
        "a technical support agent who troubleshoots devices, software, connectivity and account access issues.",
    ),
    domain_agent(
        "Billing Agent",
        "Handles invoices, duplicate or unexpected charges, refunds, payment methods, "
        "subscription plans, upgrades, downgrades, and cancellations.",
        "a billing support agent who handles invoices, charges, refunds, payment methods and subscriptions.",
    ),
    domain_agent(
        "Travel Agent",
        "Plans and changes trips: flights, hotels, itineraries, baggage rules, "
        "visas and entry requirements, seat selection, and travel insurance.",
        "a travel agent who plans and changes trips: flights, hotels, baggage, visas, seats and insurance.",
    ),
    domain_agent(
        "Wellness Agent",
        "Advises on nutrition, meal planning, exercise routines, sleep quality, "
        "hydration, stress management, and general healthy-habit questions.",
        "a wellness coach who advises on nutrition, exercise, sleep, hydration and healthy habits.",
    ),
]


def create_classifier() -> JevClassifier:
    # api_key defaults to TYPESAFE_API_KEY; JEV_API_URL can point at a
    # gateway or a local stub instead of the official endpoint.
    classifier = JevClassifier(JevClassifierOptions(base_url=os.environ.get("JEV_API_URL")))

    # Keyed by agent id, which is what the orchestrator does internally.
    classifier.set_agents({agent.id: agent for agent in agents})
    return classifier


def print_agents() -> None:
    print("Registered agents:")
    for agent in agents:
        print(f"  {agent.id}")
    print()


def estimate_cost(usage: Optional[dict[str, Any]]) -> Optional[float]:
    input_tokens = (usage or {}).get("input_tokens")
    if not isinstance(input_tokens, (int, float)):
        return None
    return input_tokens * JEV_USD_PER_MILLION_INPUT_TOKENS / 1_000_000


def format_usd(value: Optional[float]) -> str:
    if value is None:
        return "(not reported)"
    # Costs can be fractions of a cent; keep up to 8 decimals and trim trailing
    # zeros so e.g. 0.0005 prints as $0.0005, not $0.00 or $0.
    return "$" + f"{value:.8f}".rstrip("0").rstrip(".")


class TokenTotals:
    """Running token totals; only input tokens are billed."""

    def __init__(self) -> None:
        self.input = 0
        self.output = 0

    def add(self, usage: Optional[dict[str, Any]]) -> None:
        self.input += token_count(usage, "input_tokens") or 0
        self.output += token_count(usage, "output_tokens") or 0


def token_count(usage: Optional[dict[str, Any]], key: str) -> Optional[int]:
    value = (usage or {}).get(key)
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def format_tokens(input_tokens: Optional[int], output_tokens: Optional[int]) -> str:
    def count(value: Optional[int]) -> str:
        return "(not reported)" if value is None else f"{value:,}"
    return f"{count(input_tokens)} input (billed), {count(output_tokens)} output (free)"


def print_result(agent_name: Optional[str], confidence: float,
                 usage: Optional[dict[str, Any]], cost: Optional[float]) -> None:
    print(f"  agent:      {agent_name or '(none - unknown)'}")
    print(f"  confidence: {confidence:.3f}")
    print(f"  tokens:     {format_tokens(token_count(usage, 'input_tokens'), token_count(usage, 'output_tokens'))}")
    suffix = " (estimated from input tokens)" if cost is not None else ""
    print(f"  cost:       {format_usd(cost)}{suffix}")


# Each query targets one domain, except the last two, which are deliberately
# ambiguous and out of scope to show how low confidence and "unknown" surface.
queries = [
    "I was charged twice for my subscription this month",
    "My laptop won't connect to the office Wi-Fi anymore",
    "How many bags can I check on an international flight?",
    "What should I eat before an early morning workout?",
    "Can I get a refund for the flight I booked?",
    "What's the capital of Portugal?",
]


def message(role: ParticipantRole, text: str) -> ConversationMessage:
    return ConversationMessage(role=role.value, content=[{"text": text}])


async def run_scripted() -> None:
    classifier = create_classifier()
    print_agents()

    total_cost = 0.0
    total_tokens = TokenTotals()
    first_response = True

    for query in queries:
        result = await classifier.classify(query, [])
        usage = classifier.get_last_usage()
        cost = estimate_cost(usage)
        total_cost += cost or 0.0
        total_tokens.add(usage)

        # Print the raw response body once, so the actual response shape
        # (including the versioned model that answered) is visible.
        if first_response:
            print(f"(raw response from the API: {json.dumps(classifier.get_last_response())})\n")
            first_response = False

        print(f"> {query}")
        print_result(result.selected_agent and result.selected_agent.name, result.confidence, usage, cost)
        print()

    # A follow-up turn: on its own "yes, please" is meaningless, so the classifier
    # relies on the history to stay with the agent that handled the last turn.
    history = [
        message(ParticipantRole.USER, "What should I eat before an early morning workout?"),
        message(
            ParticipantRole.ASSISTANT,
            "[Wellness Agent]: Something light and carb-forward about 30-60 minutes "
            "before, like a banana or toast. Want a few more options?",
        ),
    ]

    follow_up = await classifier.classify("yes, please", history)
    usage = classifier.get_last_usage()
    follow_up_cost = estimate_cost(usage)
    total_cost += follow_up_cost or 0.0
    total_tokens.add(usage)

    print('> "yes, please" (follow-up, with history)')
    print_result(follow_up.selected_agent and follow_up.selected_agent.name,
                 follow_up.confidence, usage, follow_up_cost)
    print()

    print(f"Total tokens: {format_tokens(total_tokens.input, total_tokens.output)}")
    print(f"Total cost: {format_usd(total_cost)} (estimated from input tokens)")


async def run_interactive() -> None:
    classifier = create_classifier()
    print_agents()

    # The history grows turn by turn, so short follow-ups like "yes" or "tell me
    # more" keep routing to the agent that answered the previous turn.
    history: list[ConversationMessage] = []
    total_cost = 0.0
    total_tokens = TokenTotals()
    first_response = True

    print("Type a query and press Enter to see where it routes. Type 'exit' to quit.\n")

    try:
        while True:
            try:
                user_input = (await asyncio.to_thread(input, "You: ")).strip()
            except EOFError:  # Ctrl-D or end of piped input
                break

            if user_input.lower() == "exit":
                break
            if not user_input:
                continue

            try:
                result = await classifier.classify(user_input, history)
                usage = classifier.get_last_usage()
                cost = estimate_cost(usage)
                total_cost += cost or 0.0
                total_tokens.add(usage)

                if first_response:
                    print(f"(raw response from the API: {json.dumps(classifier.get_last_response())})")
                    first_response = False

                agent = result.selected_agent
                print_result(agent and agent.name, result.confidence, usage, cost)

                if agent:
                    # Let the Bedrock agent answer, and record both turns so the next
                    # classification sees the conversation so far. The agent name is
                    # prefixed into the assistant turn, so the classifier knows who
                    # answered when it routes a short follow-up.
                    reply = await agent.process_request(user_input, "demo-user", "demo-session", history)
                    # The model can return several content blocks (e.g. a reasoning
                    # block before the text), so collect the text from all of them.
                    text = "\n".join(
                        block["text"] for block in (reply.content or [])
                        if isinstance(block, dict) and isinstance(block.get("text"), str) and block["text"]
                    )

                    if text:
                        reply_text = f"[{agent.name}] {text}"
                        print(f"  response:   {reply_text}")
                        history.extend([
                            message(ParticipantRole.USER, user_input),
                            message(ParticipantRole.ASSISTANT, reply_text),
                        ])
                    else:
                        # Usually means maxTokens ran out before any text was produced.
                        print(f"  response:   (agent returned no text; raw reply: {reply.content!r})")
                else:
                    print("  response:   (no agent matched; turn not added to history)")
            except Exception as error:
                print(f"Error: {error}", file=sys.stderr)

            print()
    except KeyboardInterrupt:
        pass

    print(f"\nTotal tokens this session: {format_tokens(total_tokens.input, total_tokens.output)}")
    print(f"Total cost this session: {format_usd(total_cost)} (estimated from input tokens)")


if __name__ == "__main__":
    interactive = "--interactive" in sys.argv or "-i" in sys.argv
    try:
        asyncio.run(run_interactive() if interactive else run_scripted())
    except Exception as error:
        print(f"FAILED: {error}", file=sys.stderr)
        sys.exit(1)
