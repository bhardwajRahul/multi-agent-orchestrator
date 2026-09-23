/**
 * Side-by-side classifier comparison: JevClassifier vs BedrockClassifier.
 *
 * Runs the same scripted multi-turn conversation through both classifiers.
 * The conversation deliberately interleaves agents: an agent proposes
 * something, the user switches to another domain, and only answers the
 * pending proposal ("yes, please go ahead") one or two turns later. Routing
 * those answers correctly requires understanding which question is still
 * open in the history - "same agent as the last turn" gives the wrong answer.
 *
 * Run from this directory (examples/jev-demo/typescript), after `npm install`:
 *   export TYPESAFE_API_KEY=...
 *   # plus AWS credentials with bedrock:InvokeModel access (AWS_PROFILE/AWS_REGION)
 *   npm run compare
 *
 * At the end it prints accuracy, latency and cost for each classifier and the
 * relative difference. Both costs are estimated from token counts:
 *   - Jev:     JEV_USD_PER_MTOK per million input tokens, output free
 *              (defaults to the official $0.042 rate, https://docs.typesafe.ai/models)
 *   - Bedrock: BEDROCK_INPUT_USD_PER_MTOK / BEDROCK_OUTPUT_USD_PER_MTOK
 *              (defaults below), since the Converse API reports tokens, not dollars.
 */

import { Agent, AgentOptions } from "../../../typescript/src/agents/agent";
import { BedrockClassifier } from "../../../typescript/src/classifiers/bedrockClassifier";
import { Classifier } from "../../../typescript/src/classifiers/classifier";
import { JevClassifier } from "../../../typescript/src/classifiers/jevClassifier";
import { ConversationMessage, ParticipantRole } from "../../../typescript/src/types";

const BEDROCK_CLASSIFIER_MODEL_ID =
  process.env.BEDROCK_CLASSIFIER_MODEL_ID ?? "us.anthropic.claude-opus-5";

// Estimated Bedrock pricing for the model above, in USD per million tokens.
// Override with env vars if your account's rate differs.
const BEDROCK_INPUT_USD_PER_MTOK = Number(process.env.BEDROCK_INPUT_USD_PER_MTOK ?? 5);
const BEDROCK_OUTPUT_USD_PER_MTOK = Number(process.env.BEDROCK_OUTPUT_USD_PER_MTOK ?? 25);

// Official Jev 1.13 pricing: $0.042 per million input tokens, output tokens
// free (https://docs.typesafe.ai/models). Override if you call Jev through a
// gateway with its own rate.
const JEV_USD_PER_MILLION_INPUT_TOKENS = Number(process.env.JEV_USD_PER_MTOK ?? 0.042);

/** Minimal agent stub: only id/name/description matter for classification. */
class DomainAgent extends Agent {
  constructor(options: AgentOptions) {
    super(options);
    this.description = options.description;
  }

  async processRequest(): Promise<ConversationMessage> {
    throw new Error("This demo never invokes the agents themselves");
  }
}

const agents = [
  new DomainAgent({
    name: "Tech Support Agent",
    description:
      "Troubleshoots devices, software errors, crashes, login and password problems, " +
      "Wi-Fi and connectivity issues, installations, and account access.",
  }),
  new DomainAgent({
    name: "Billing Agent",
    description:
      "Handles invoices, duplicate or unexpected charges, refunds, payment methods, " +
      "subscription plans, upgrades, downgrades, and cancellations.",
  }),
  new DomainAgent({
    name: "Travel Agent",
    description:
      "Plans and changes trips: flights, hotels, itineraries, baggage rules, " +
      "visas and entry requirements, seat selection, and travel insurance.",
  }),
  new DomainAgent({
    name: "Wellness Agent",
    description:
      "Advises on nutrition, meal planning, exercise routines, sleep quality, " +
      "hydration, stress management, and general healthy-habit questions.",
  }),
];

const agentsById = Object.fromEntries(agents.map((agent) => [agent.id, agent]));

/**
 * BedrockClassifier does not expose token usage, so this subclass captures it
 * from the deserialized Converse response via SDK middleware.
 */
class MeteredBedrockClassifier extends BedrockClassifier {
  lastUsage?: { inputTokens?: number; outputTokens?: number };

  constructor(options: ConstructorParameters<typeof BedrockClassifier>[0]) {
    super(options);
    this.client.middlewareStack.add(
      (next) => async (args) => {
        const result = await next(args);
        const usage = (result.output as { usage?: MeteredBedrockClassifier["lastUsage"] })?.usage;
        if (usage) {
          this.lastUsage = usage;
        }
        return result;
      },
      { step: "deserialize", name: "captureConverseUsage" }
    );
  }
}

// The scripted conversation. Each turn is classified against the history of
// all previous turns; the canned agent reply (with the [Agent Name] prefix,
// as an orchestrator would store it) is appended afterwards so follow-ups
// and context switches have real history to route against.
interface Turn {
  user: string;
  expected: string; // agent id
  reply: string;
}

const conversation: Turn[] = [
  {
    // Billing proposes an action and leaves the question open.
    user: "I was charged twice for my subscription this month",
    expected: "billing-agent",
    reply:
      "[Billing Agent] I can open a refund request for the duplicate charge right away - " +
      "it takes 3-5 business days to land. Shall I proceed?",
  },
  {
    // The user switches to tech support before answering. The tech reply is
    // deliberately a statement, so billing's proposal stays the only open question.
    user: "hold on - my laptop won't connect to the office Wi-Fi anymore",
    expected: "tech-support-agent",
    reply:
      "[Tech Support Agent] Restart the laptop, then forget and rejoin the network. " +
      "If it still fails, update the Wi-Fi driver from the manufacturer's site.",
  },
  {
    // Interleaved follow-up: this answers billing's proposal from two turns
    // ago, not the tech support turn right before it.
    user: "yes, please go ahead",
    expected: "billing-agent",
    reply:
      "[Billing Agent] Done, the refund request is submitted; you'll get a confirmation " +
      "email shortly.",
  },
  {
    // Back to tech support; its reply ends with a pending offer.
    user: "the wifi is still not working after doing all that",
    expected: "tech-support-agent",
    reply:
      "[Tech Support Agent] Then set your DNS to 1.1.1.1 and try again. I can also walk " +
      "you through checking the adapter logs - want me to?",
  },
  {
    // Travel interleaves, leaving a second pending question (which airline).
    user: "How many bags can I check on a flight to Tokyo?",
    expected: "travel-agent",
    reply:
      "[Travel Agent] Most airlines include one 23 kg checked bag to Tokyo in economy; " +
      "a second bag is usually 75-100 USD. Which airline are you flying?",
  },
  {
    // Two questions are pending (tech's offer, travel's airline). This one
    // answers tech support's "walk you through" offer from two turns ago.
    user: "yes, walk me through it",
    expected: "tech-support-agent",
    reply:
      "[Tech Support Agent] Open the system's network logs and look for adapter resets " +
      "or DHCP errors; tell me what you find.",
  },
  {
    // And this one answers travel's "which airline" question from turn 5.
    user: "it's ANA",
    expected: "travel-agent",
    reply:
      "[Travel Agent] ANA includes two 23 kg checked bags on international routes, so " +
      "you're covered without extra fees.",
  },
  {
    // A fresh domain; wellness leaves an offer open ("more options?").
    user: "what should I eat before an early morning workout?",
    expected: "wellness-agent",
    reply:
      "[Wellness Agent] Something light and carb-forward 30-60 minutes before: a banana, " +
      "toast with honey, or a small bowl of oatmeal. Want a few more options?",
  },
  {
    // Billing interleaves again with a direct question; the reply is a
    // statement, so wellness's offer stays the only open question.
    user: "did the refund confirmation email go out yet?",
    expected: "billing-agent",
    reply:
      "[Billing Agent] Yes, it was sent a few minutes ago - check your spam folder if " +
      "you don't see it.",
  },
  {
    // Answers wellness's "more options?" offer from two turns ago.
    user: "yes, a couple more please",
    expected: "wellness-agent",
    reply:
      "[Wellness Agent] Dates with peanut butter, a rice cake with jam, or half a bagel. " +
      "Should I put together a weekly pre-workout meal plan for you?",
  },
  {
    // Travel interleaves with a visa question; again answered with a statement.
    user: "one more thing - do I need a visa for Japan as a French citizen?",
    expected: "travel-agent",
    reply:
      "[Travel Agent] No - French citizens can stay in Japan visa-free for up to 90 days " +
      "for tourism.",
  },
  {
    // Closes wellness's pending meal-plan offer from two turns ago.
    user: "ok, put it together for me",
    expected: "wellness-agent",
    reply:
      "[Wellness Agent] Done - a 7-day pre-workout meal plan alternating oatmeal and " +
      "toast days, around 250 kcal each, is on its way.",
  },
];

interface TurnResult {
  agentId: string; // "(unknown)" when no agent matched, "(error)" on failure
  confidence: number;
  latencyMs: number;
  costUsd: number;
  correct: boolean;
}

function formatUsd(value: number): string {
  return `$${value.toFixed(8).replace(/0+$/, "").replace(/\.$/, "")}`;
}

async function classifyTimed(
  classifier: Classifier,
  input: string,
  history: ConversationMessage[],
  expected: string,
  costOfLastCall: () => number
): Promise<TurnResult> {
  const start = performance.now();
  try {
    const result = await classifier.classify(input, history);
    const latencyMs = performance.now() - start;
    const agentId = result.selectedAgent?.id ?? "(unknown)";
    return {
      agentId,
      confidence: result.confidence,
      latencyMs,
      costUsd: costOfLastCall(),
      correct: agentId === expected,
    };
  } catch (error) {
    return {
      agentId: `(error: ${error instanceof Error ? error.message : error})`,
      confidence: 0,
      latencyMs: performance.now() - start,
      costUsd: 0,
      correct: false,
    };
  }
}

function printTurnLine(label: string, r: TurnResult): void {
  console.log(
    `  ${label.padEnd(8)}: ${r.agentId.padEnd(20)} conf ${r.confidence.toFixed(2)}  ` +
      `${Math.round(r.latencyMs).toString().padStart(5)}ms  ` +
      `${formatUsd(r.costUsd).padEnd(11)} ${r.correct ? "OK" : "MISS"}`
  );
}

function summarize(label: string, results: TurnResult[]): void {
  const correct = results.filter((r) => r.correct).length;
  const totalMs = results.reduce((sum, r) => sum + r.latencyMs, 0);
  const totalUsd = results.reduce((sum, r) => sum + r.costUsd, 0);
  console.log(
    `  ${label.padEnd(8)}: ${correct}/${results.length} correct   ` +
      `avg ${Math.round(totalMs / results.length).toString().padStart(5)}ms   ` +
      `total ${Math.round(totalMs).toString().padStart(6)}ms   ` +
      `cost ${formatUsd(totalUsd)}`
  );
}

async function main(): Promise<void> {
  const jev = new JevClassifier({ baseUrl: process.env.JEV_API_URL });
  jev.setAgents(agentsById);

  const bedrock = new MeteredBedrockClassifier({
    modelId: BEDROCK_CLASSIFIER_MODEL_ID,
    region: process.env.AWS_REGION ?? process.env.REGION,
  });
  bedrock.setAgents(agentsById);

  console.log(`Jev model:     jev-latest (${process.env.JEV_API_URL ?? "default endpoint"})`);
  console.log(`Bedrock model: ${BEDROCK_CLASSIFIER_MODEL_ID}\n`);

  const history: ConversationMessage[] = [];
  const jevResults: TurnResult[] = [];
  const bedrockResults: TurnResult[] = [];

  for (const [index, turn] of conversation.entries()) {
    console.log(`Turn ${index + 1}/${conversation.length} > "${turn.user}"`);
    console.log(`  expected: ${turn.expected}`);

    // Same input, same history, for both classifiers.
    const jevResult = await classifyTimed(jev, turn.user, history, turn.expected, () => {
      const tokens = Number(jev.getLastUsage()?.input_tokens ?? 0);
      return (tokens * JEV_USD_PER_MILLION_INPUT_TOKENS) / 1_000_000;
    });
    const bedrockResult = await classifyTimed(bedrock, turn.user, history, turn.expected, () => {
      const usage = bedrock.lastUsage;
      return (
        ((usage?.inputTokens ?? 0) * BEDROCK_INPUT_USD_PER_MTOK) / 1_000_000 +
        ((usage?.outputTokens ?? 0) * BEDROCK_OUTPUT_USD_PER_MTOK) / 1_000_000
      );
    });

    printTurnLine("jev", jevResult);
    printTurnLine("bedrock", bedrockResult);
    console.log();

    jevResults.push(jevResult);
    bedrockResults.push(bedrockResult);

    // Advance the shared conversation with the scripted agent reply.
    history.push(
      { role: ParticipantRole.USER, content: [{ text: turn.user }] },
      { role: ParticipantRole.ASSISTANT, content: [{ text: turn.reply }] }
    );
  }

  console.log(`=== Summary (${conversation.length} turns) ===`);
  summarize("jev", jevResults);
  summarize("bedrock", bedrockResults);

  const jevAvgMs = jevResults.reduce((s, r) => s + r.latencyMs, 0) / jevResults.length;
  const bedrockAvgMs =
    bedrockResults.reduce((s, r) => s + r.latencyMs, 0) / bedrockResults.length;
  const jevCost = jevResults.reduce((s, r) => s + r.costUsd, 0);
  const bedrockCost = bedrockResults.reduce((s, r) => s + r.costUsd, 0);

  console.log();
  if (jevAvgMs > 0 && bedrockAvgMs > 0) {
    const [fast, slow, ratio] =
      jevAvgMs <= bedrockAvgMs
        ? ["jev", "bedrock", bedrockAvgMs / jevAvgMs]
        : ["bedrock", "jev", jevAvgMs / bedrockAvgMs];
    console.log(`Latency: ${fast} was ${ratio.toFixed(1)}x faster than ${slow} on average.`);
  }
  if (jevCost > 0 && bedrockCost > 0) {
    const [cheap, dear, ratio] =
      jevCost <= bedrockCost
        ? ["jev", "bedrock", bedrockCost / jevCost]
        : ["bedrock", "jev", jevCost / bedrockCost];
    console.log(
      `Cost:    ${cheap} was ${ratio.toFixed(1)}x cheaper than ${dear} ` +
        `(both estimated from token counts).`
    );
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error("FAILED:", error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
