import {
  ConversationMessage,
  JEV_DECISION_API_URL,
  JEV_MODEL_ID_LATEST,
} from "../types";
import { Logger } from "../utils/logger";
import { Classifier, ClassifierCallbacks, ClassifierResult } from "./classifier";

// The label offered to Jev when none of the registered agents fit the request.
// It is deliberately not a valid agent id, so getAgentById resolves it to null.
const UNKNOWN_AGENT_LABEL = "unknown";

// Jev's `choice` decision type accepts at most 255 labelled options.
const MAX_CHOICE_CRITERIA = 255;

// Environment variable read when no apiKey is passed, as in the official TypeSafe SDKs.
const API_KEY_ENV_VAR = "TYPESAFE_API_KEY";

// Statuses retried with backoff, matching the official SDKs' default policy:
// 408, 429 (rate limited) and 5xx (including 529 Overloaded).
const isRetryableStatus = (status: number) =>
  status === 408 || status === 429 || (status >= 500 && status < 600);
const BACKOFF_INITIAL_MS = 500;
const BACKOFF_MAX_MS = 5000;

const DEFAULT_INSTRUCTIONS = `Select the single agent best equipped to handle the current user input.

The input may be a follow-up (e.g. "yes", "ok", "tell me more", "1"). Follow-ups answer a pending question or proposal in the conversation, which is not necessarily in the most recent turn: an agent may have asked something, the user switched topics to another agent, and is only now answering the earlier question. Select the agent whose pending question or proposal the input responds to.

If none of the agents is a reasonable fit, select "${UNKNOWN_AGENT_LABEL}".`;

// The agent descriptions already travel as the choice criteria, so the state
// only carries the conversation. Jev loses accuracy on large states full of
// unrelated detail, which rules out the base class's LLM-oriented prompt.
const DEFAULT_PROMPT_TEMPLATE = `<conversation_history>
{{HISTORY}}
</conversation_history>`;

export interface JevClassifierOptions {
  // Optional: The Jev model to use for decisions, e.g. "jev-latest" or a
  // pinned version like "jev-1.13.0". Pin a version in production so
  // decision thresholds don't shift. Defaults to "jev-latest".
  modelId?: string;

  // Optional: The API key for authenticating with the TypeSafe API.
  // Falls back to the TYPESAFE_API_KEY environment variable when omitted.
  apiKey?: string;

  // Optional: Override the System One endpoint
  // (for example to target a gateway or a compatible endpoint, or a stub in tests)
  baseUrl?: string;

  // Optional: Replace the routing instructions sent with the choice question
  instructions?: string;

  // Optional: Abort each request attempt after this many milliseconds
  timeoutMs?: number;

  // Optional: Retries on 408, 429 and 5xx responses, with exponential backoff.
  // Defaults to 2.
  maxRetries?: number;

  callbacks?: ClassifierCallbacks;
}

// Token usage Jev reports alongside every decision. Only input tokens are
// billed.
export interface JevUsage {
  input_tokens?: number;
  output_tokens?: number;
  [key: string]: unknown;
}

interface JevChoiceAnswer {
  type?: string;
  choice: string;
  confidence: number;
  probabilities?: Record<string, number>;
}

function isJevChoiceAnswer(answer: unknown): answer is JevChoiceAnswer {
  if (typeof answer !== "object" || answer === null) {
    return false;
  }
  const candidate = answer as Partial<JevChoiceAnswer>;
  return (
    typeof candidate.choice === "string" &&
    typeof candidate.confidence === "number" &&
    (candidate.type === undefined || candidate.type === "choice")
  );
}

/**
 * Classifier backed by the TypeSafe Jev System One API.
 *
 * Unlike the model-backed classifiers, Jev returns a typed decision rather than
 * free text or a tool call: the registered agents are sent as the `criteria` of
 * a `choice` question, and Jev replies with the winning label plus a calibrated
 * confidence. The prompt template is used as the `state` the decision is made
 * against, so custom system prompts keep working.
 */
export class JevClassifier extends Classifier {
  private readonly apiKey: string;
  private readonly baseUrl: string;
  private readonly instructions: string;
  private readonly timeoutMs: number;
  private readonly maxRetries: number;
  protected callbacks: ClassifierCallbacks;

  // Token usage reported by Jev for the most recent decision, if any.
  private lastUsage?: JevUsage;

  // Full parsed body of the most recent successful response, including the
  // versioned model id that answered.
  private lastResponse?: unknown;

  constructor(options: JevClassifierOptions = {}) {
    super();

    const apiKey = options.apiKey || process.env[API_KEY_ENV_VAR];
    if (!apiKey) {
      throw new Error(
        `Jev API key is required: pass options.apiKey or set the ${API_KEY_ENV_VAR} environment variable`
      );
    }

    this.apiKey = apiKey;
    this.modelId = options.modelId || JEV_MODEL_ID_LATEST;
    this.baseUrl = options.baseUrl || JEV_DECISION_API_URL;
    this.instructions = options.instructions || DEFAULT_INSTRUCTIONS;
    this.timeoutMs = options.timeoutMs ?? 30000;
    this.maxRetries = Math.max(0, options.maxRetries ?? 2);
    this.callbacks = options.callbacks ?? new ClassifierCallbacks();
    this.promptTemplate = DEFAULT_PROMPT_TEMPLATE;
  }

  /**
   * Returns the token usage Jev reported for the most recent decision, or
   * undefined if no decision has completed yet.
   */
  getLastUsage(): JevUsage | undefined {
    return this.lastUsage;
  }

  /**
   * Returns the full parsed body of the most recent successful Jev response,
   * or undefined if no decision has completed yet. Its `model` field holds the
   * versioned model id that answered, which is useful to log.
   */
  getLastResponse(): unknown {
    return this.lastResponse;
  }

  /**
   * Turns the registered agents into the criteria map of a `choice` question.
   * Keys are agent ids, which is what getAgentById expects back.
   */
  private buildCriteria(): Record<string, string> {
    const agents = this.agents ?? {};
    const criteria: Record<string, string> = {};

    for (const agent of Object.values(agents)) {
      criteria[agent.id] = agent.description;
    }

    if (Object.keys(criteria).length === 0) {
      throw new Error("No agents registered: call setAgents before classifying");
    }

    if (UNKNOWN_AGENT_LABEL in criteria) {
      throw new Error(
        `The agent id "${UNKNOWN_AGENT_LABEL}" is reserved by JevClassifier; rename that agent`
      );
    }

    criteria[UNKNOWN_AGENT_LABEL] =
      "None of the other agents is a reasonable fit for this request.";

    if (Object.keys(criteria).length > MAX_CHOICE_CRITERIA) {
      throw new Error(
        `Jev choice decisions support at most ${MAX_CHOICE_CRITERIA} options, ` +
          `including "${UNKNOWN_AGENT_LABEL}"; ${Object.keys(criteria).length} were provided`
      );
    }

    return criteria;
  }

  /**
   * Method to process a request.
   *
   * @param inputText - The user input as a string.
   * @param chatHistory - An array of Message objects representing the conversation history.
   * @returns A Promise that resolves to a ClassifierResult object containing the classification outcome.
   */
  async processRequest(
    inputText: string,
    chatHistory: ConversationMessage[]
  ): Promise<ClassifierResult> {
    const requestBody = {
      model: this.modelId,
      // systemPrompt holds the interpolated prompt template (the conversation
      // history by default); the current turn is appended so the decision is
      // made against the full context.
      state: `${this.systemPrompt}\n\n<current_user_input>\n${inputText}\n</current_user_input>`,
      questions: {
        selected_agent: {
          type: "choice",
          instructions: this.instructions,
          criteria: this.buildCriteria(),
        },
      },
    };

    await this.callbacks.onClassifierStart("JevClassifier", { inputText, chatHistory });

    try {
      const payload = await this.send(requestBody);
      const answer = payload?.answers?.selected_agent;

      if (!isJevChoiceAnswer(answer)) {
        throw new Error("No valid 'selected_agent' choice answer found in the Jev response");
      }

      this.lastResponse = payload;
      this.lastUsage = payload.usage;

      const intentClassifierResult: ClassifierResult = {
        selectedAgent:
          answer.choice === UNKNOWN_AGENT_LABEL ? null : this.getAgentById(answer.choice),
        confidence: answer.confidence,
      };

      await this.callbacks.onClassifierStop("JevClassifier", {
        ...intentClassifierResult,
        usage: this.lastUsage,
      });

      return intentClassifierResult;
    } catch (error) {
      if (error instanceof Error && error.name === "AbortError") {
        const timeoutError = new Error(`Jev request timed out after ${this.timeoutMs}ms`);
        Logger.logger.error("Error processing request:", timeoutError);
        throw timeoutError;
      }
      Logger.logger.error("Error processing request:", error);
      // Instead of returning a default result, we'll throw the error
      throw error;
    }
  }

  /**
   * Posts the request, retrying 408, 429 and 5xx responses with exponential
   * backoff (or the delay the Retry-After header asks for). The timeout
   * applies to each attempt, including reading the response body.
   */
  private async send(requestBody: unknown): Promise<any> {
    for (let attempt = 0; ; attempt++) {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
      let retryDelayMs: number;

      try {
        const response = await fetch(this.baseUrl, {
          method: "POST",
          headers: {
            // The key is only ever sent in this header, never logged.
            Authorization: `Bearer ${this.apiKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(requestBody),
          signal: controller.signal,
        });

        if (response.ok) {
          return await response.json();
        }

        if (!isRetryableStatus(response.status) || attempt >= this.maxRetries) {
          throw new Error(await this.describeHttpError(response));
        }

        retryDelayMs = this.retryDelayMs(response, attempt);
      } finally {
        clearTimeout(timeout);
      }

      await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
    }
  }

  private retryDelayMs(response: Response, attempt: number): number {
    const retryAfter = response.headers?.get("retry-after");
    const seconds = retryAfter ? Number(retryAfter) : NaN;
    if (Number.isFinite(seconds) && seconds >= 0) {
      return seconds * 1000;
    }
    return Math.min(BACKOFF_INITIAL_MS * 2 ** attempt, BACKOFF_MAX_MS);
  }

  private async describeHttpError(response: Response): Promise<string> {
    const detail = await response.text().catch(() => "");
    return `Jev request failed: ${response.status} ${response.statusText}${
      detail ? ` - ${detail}` : ""
    }`;
  }
}
