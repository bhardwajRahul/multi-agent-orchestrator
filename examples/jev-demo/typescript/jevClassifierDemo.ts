/**
 * JevClassifier demo: routing across four unrelated domains, with real agent
 * responses from Amazon Bedrock so multi-turn conversations can be tested.
 *
 * Run from this directory (examples/jev-demo/typescript), after `npm install`:
 *   export TYPESAFE_API_KEY=...
 *   # plus AWS credentials with bedrock:InvokeModel access (AWS_PROFILE/AWS_REGION)
 *   npm run demo               # scripted queries
 *   npm run demo:interactive   # type your own
 *
 * The classifier only needs the Jev key; the agents call Bedrock (Claude
 * Sonnet 5 by default, override with BEDROCK_MODEL_ID) to answer once a turn
 * has been routed. Scripted mode never calls Bedrock, only the classifier.
 */

import readline from "readline";
import { BedrockLLMAgent } from "../../../typescript/src/agents/bedrockLLMAgent";
import { JevClassifier, JevUsage } from "../../../typescript/src/classifiers/jevClassifier";
import { ConversationMessage, ParticipantRole } from "../../../typescript/src/types";

/**
 * Real Bedrock-backed agents, one per domain. Answers are kept short and end
 * with a follow-up question, so the conversation history gives the classifier
 * something to route short replies like "yes" or "tell me more" against.
 */
function domainAgent(name: string, description: string, role: string): BedrockLLMAgent {
  return new BedrockLLMAgent({
    name,
    description,
    modelId: process.env.BEDROCK_MODEL_ID ?? "us.anthropic.claude-sonnet-5",
    inferenceConfig: { maxTokens: 1024 },
    customSystemPrompt: {
      template:
        `You are ${role} Answer in 2-4 sentences, and when a natural next step ` +
        `exists, end with a short follow-up question offering it.`,
    },
  });
}

const agents = [
  domainAgent(
    "Tech Support Agent",
    "Troubleshoots devices, software errors, crashes, login and password problems, " +
      "Wi-Fi and connectivity issues, installations, and account access.",
    "a technical support agent who troubleshoots devices, software, connectivity and account access issues."
  ),
  domainAgent(
    "Billing Agent",
    "Handles invoices, duplicate or unexpected charges, refunds, payment methods, " +
      "subscription plans, upgrades, downgrades, and cancellations.",
    "a billing support agent who handles invoices, charges, refunds, payment methods and subscriptions."
  ),
  domainAgent(
    "Travel Agent",
    "Plans and changes trips: flights, hotels, itineraries, baggage rules, " +
      "visas and entry requirements, seat selection, and travel insurance.",
    "a travel agent who plans and changes trips: flights, hotels, baggage, visas, seats and insurance."
  ),
  domainAgent(
    "Wellness Agent",
    "Advises on nutrition, meal planning, exercise routines, sleep quality, " +
      "hydration, stress management, and general healthy-habit questions.",
    "a wellness coach who advises on nutrition, exercise, sleep, hydration and healthy habits."
  ),
];

function createClassifier(): JevClassifier {
  const classifier = new JevClassifier({
    // apiKey defaults to TYPESAFE_API_KEY; JEV_API_URL can
    // point at a gateway or a local stub instead of the official endpoint.
    baseUrl: process.env.JEV_API_URL,
  });

  // Keyed by agent id, which is what the orchestrator does internally.
  classifier.setAgents(Object.fromEntries(agents.map((agent) => [agent.id, agent])));
  return classifier;
}

function printAgents(): void {
  console.log("Registered agents:");
  for (const agent of agents) {
    console.log(`  ${agent.id}`);
  }
  console.log();
}

/** Accepts numbers and numeric strings, since live APIs send both. */
function asNumber(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value))) {
    return Number(value);
  }
  return undefined;
}

// Official Jev 1.13 pricing: $0.042 per million input tokens, output tokens
// free (https://docs.typesafe.ai/models). The API reports token counts, not
// dollars, so the cost is estimated. Override JEV_USD_PER_MTOK if you call
// Jev through a gateway with its own rate.
const JEV_USD_PER_MILLION_INPUT_TOKENS = Number(process.env.JEV_USD_PER_MTOK ?? 0.042);

interface CostInfo {
  usd: number;
  // Always true: derived from input_tokens and the published rate.
  estimated: boolean;
}

function extractCost(usage: JevUsage | undefined): CostInfo | undefined {
  const inputTokens = asNumber(usage?.input_tokens);
  if (inputTokens === undefined) {
    return undefined;
  }
  return { usd: (inputTokens * JEV_USD_PER_MILLION_INPUT_TOKENS) / 1_000_000, estimated: true };
}

function formatUsd(value: unknown): string {
  const numeric = asNumber(value);
  if (numeric === undefined) {
    return "(not reported)";
  }
  // Costs can be fractions of a cent; keep up to 8 decimals and trim trailing
  // zeros so e.g. 0.0005 prints as $0.0005, not $0.00 or $0.
  const formatted = numeric.toFixed(8).replace(/0+$/, "").replace(/\.$/, "");
  return `$${formatted}`;
}

function printResult(
  selectedAgentName: string | undefined,
  confidence: number,
  cost: CostInfo | undefined
): void {
  console.log(`  agent:      ${selectedAgentName ?? "(none - unknown)"}`);
  console.log(`  confidence: ${confidence.toFixed(3)}`);
  const suffix = cost?.estimated ? " (estimated from input tokens)" : "";
  console.log(`  cost:       ${formatUsd(cost?.usd)}${suffix}`);
}

// Each query targets one domain, except the last two, which are deliberately
// ambiguous and out of scope to show how low confidence and "unknown" surface.
const queries = [
  "I was charged twice for my subscription this month",
  "My laptop won't connect to the office Wi-Fi anymore",
  "How many bags can I check on an international flight?",
  "What should I eat before an early morning workout?",
  "Can I get a refund for the flight I booked?",
  "What's the capital of Portugal?",
];

async function runScripted(): Promise<void> {
  const classifier = createClassifier();
  printAgents();

  let totalCostUsd = 0;
  let anyEstimated = false;
  let firstUsage = true;

  for (const query of queries) {
    const result = await classifier.classify(query, []);
    const usage = classifier.getLastUsage();
    const cost = extractCost(usage);
    totalCostUsd += cost?.usd ?? 0;
    anyEstimated ||= cost?.estimated ?? false;

    // Print the raw response body once, so any drift between the documented
    // and the actual response shape is immediately visible.
    if (firstUsage) {
      console.log(
        `(raw response from the API: ${JSON.stringify(classifier.getLastResponse())})\n`
      );
      firstUsage = false;
    }

    console.log(`> ${query}`);
    printResult(result.selectedAgent?.name, result.confidence, cost);
    console.log();
  }

  // A follow-up turn: on its own "yes, please" is meaningless, so the classifier
  // relies on the history to stay with the agent that handled the last turn.
  const history: ConversationMessage[] = [
    {
      role: ParticipantRole.USER,
      content: [{ text: "What should I eat before an early morning workout?" }],
    },
    {
      role: ParticipantRole.ASSISTANT,
      content: [
        {
          text:
            "[Wellness Agent]: Something light and carb-forward about 30-60 minutes " +
            "before, like a banana or toast. Want a few more options?",
        },
      ],
    },
  ];

  const followUp = await classifier.classify("yes, please", history);
  const usage = classifier.getLastUsage();
  const followUpCost = extractCost(usage);
  totalCostUsd += followUpCost?.usd ?? 0;
  anyEstimated ||= followUpCost?.estimated ?? false;

  console.log('> "yes, please" (follow-up, with history)');
  printResult(followUp.selectedAgent?.name, followUp.confidence, followUpCost);
  console.log();

  console.log(
    `Total cost: ${formatUsd(totalCostUsd)}${anyEstimated ? " (estimated from input tokens)" : ""}`
  );
}

async function runInteractive(): Promise<void> {
  const classifier = createClassifier();
  printAgents();

  // The history grows turn by turn, so short follow-ups like "yes" or "tell me
  // more" keep routing to the agent that answered the previous turn.
  const history: ConversationMessage[] = [];
  let totalCostUsd = 0;
  let anyEstimated = false;
  let firstUsage = true;

  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  // Fires on 'exit', Ctrl-C, Ctrl-D, and end of piped input alike.
  let closed = false;
  rl.on("close", () => {
    closed = true;
    console.log(
      `\nTotal cost this session: ${formatUsd(totalCostUsd)}${
        anyEstimated ? " (estimated from input tokens)" : ""
      }`
    );
  });

  console.log(
    "Type a query and press Enter to see where it routes. Type 'exit' to quit.\n"
  );

  const askQuestion = (): void => {
    if (closed) {
      return;
    }
    rl.question("You: ", async (userInput: string) => {
      const trimmed = userInput.trim();

      if (trimmed.toLowerCase() === "exit") {
        rl.close();
        return;
      }

      if (trimmed.length === 0) {
        askQuestion();
        return;
      }

      try {
        const result = await classifier.classify(trimmed, history);
        const usage = classifier.getLastUsage();
        const cost = extractCost(usage);
        totalCostUsd += cost?.usd ?? 0;
        anyEstimated ||= cost?.estimated ?? false;

        // Print the raw response body once, so any drift between the documented
        // and the actual response shape is immediately visible.
        if (firstUsage) {
          console.log(
            `(raw response from the API: ${JSON.stringify(classifier.getLastResponse())})`
          );
          firstUsage = false;
        }

        printResult(result.selectedAgent?.name, result.confidence, cost);

        if (result.selectedAgent) {
          // Let the Bedrock agent answer, and record both turns so the next
          // classification sees the conversation so far. The agent name is
          // prefixed into the assistant turn, so the classifier knows who
          // answered when it routes a short follow-up.
          const reply = (await result.selectedAgent.processRequest(
            trimmed,
            "demo-user",
            "demo-session",
            history
          )) as ConversationMessage;
          // The model can return several content blocks (e.g. a reasoning
          // block before the text), so collect the text from all of them.
          const text = (reply.content ?? [])
            .map((block) => (typeof block?.text === "string" ? block.text : ""))
            .filter(Boolean)
            .join("\n");

          if (text) {
            const replyText = `[${result.selectedAgent.name}] ${text}`;
            console.log(`  response:   ${replyText}`);
            history.push(
              { role: ParticipantRole.USER, content: [{ text: trimmed }] },
              { role: ParticipantRole.ASSISTANT, content: [{ text: replyText }] }
            );
          } else {
            // Usually means maxTokens ran out before any text was produced;
            // show the raw reply so the actual shape is visible.
            console.log(
              `  response:   (agent returned no text; raw reply: ${JSON.stringify(reply)})`
            );
          }
        } else {
          console.log("  response:   (no agent matched; turn not added to history)");
        }
      } catch (error) {
        console.error("Error:", error instanceof Error ? error.message : error);
      }

      console.log();
      askQuestion(); // Continue the conversation
    });
  };

  askQuestion(); // Start the conversation
}

if (require.main === module) {
  const interactive =
    process.argv.includes("--interactive") || process.argv.includes("-i");

  (interactive ? runInteractive() : runScripted()).catch((error) => {
    console.error("FAILED:", error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
