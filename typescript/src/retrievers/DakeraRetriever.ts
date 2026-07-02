import { Retriever } from "./retriever";
import { DakeraClient } from "@dakera-ai/dakera";

/**
 * Interface defining the options for DakeraRetriever.
 */
export interface DakeraRetrieverOptions {
  /** The Dakera namespace to query. */
  namespace: string;
  /** Dakera API key (a `dk-...` token). Falls back to the `DAKERA_API_KEY` env var. */
  apiKey?: string;
  /** Base URL of the Dakera server. Falls back to `DAKERA_URL`, then `http://localhost:3000`. */
  url?: string;
  /** Maximum number of results to return. Defaults to 10. */
  topK?: number;
  /** Optional Dakera metadata filter applied to the query. */
  filter?: Record<string, unknown>;
}

/**
 * Retriever backed by a self-hosted [Dakera](https://dakera.ai) memory server.
 *
 * Uses Dakera's text-query API (server-side embedding) to fetch the most relevant
 * documents for a query, which agents can use as retrieval-augmented context.
 * Extends the base {@link Retriever} class.
 */
export class DakeraRetriever extends Retriever {
  private client: DakeraClient;
  protected options: DakeraRetrieverOptions;

  /**
   * Constructor for DakeraRetriever.
   * @param options - Configuration options for the retriever.
   */
  constructor(options: DakeraRetrieverOptions) {
    super(options);
    this.options = options;

    if (!this.options.namespace) {
      throw new Error("namespace is required in options");
    }

    const apiKey = this.options.apiKey ?? process.env.DAKERA_API_KEY;
    if (!apiKey) {
      throw new Error(
        "apiKey is required (set it in options or the DAKERA_API_KEY env var)",
      );
    }
    const baseUrl = this.options.url || process.env.DAKERA_URL || "http://localhost:3000";

    this.client = new DakeraClient({ baseUrl, apiKey });
  }

  /**
   * Retrieve the documents most relevant to `text` from Dakera.
   * @param text - The query text.
   * @returns The text query results (each with `id`, `score` and `text`).
   */
  public async retrieve(text: string): Promise<any[]> {
    if (!text) {
      throw new Error("Input text is required for retrieve");
    }

    const response = await this.client.queryText(this.options.namespace, text, {
      topK: this.options.topK ?? 10,
      filter: this.options.filter as never,
    });
    return response.results;
  }

  /**
   * Retrieve results for `text` and combine their text into a single string.
   * @param text - The query text.
   * @returns The combined result text, newline-separated.
   */
  public async retrieveAndCombineResults(text: string): Promise<string> {
    const results = await this.retrieve(text);
    return this.combineRetrievalResults(results);
  }

  /**
   * Not supported: Dakera is a retrieval-only backend (no generation).
   * @throws Always, directing callers to `retrieve` / `retrieveAndCombineResults`.
   */
  public async retrieveAndGenerate(_text: string): Promise<any> {
    throw new Error(
      "DakeraRetriever does not support retrieveAndGenerate; " +
        "use retrieve or retrieveAndCombineResults.",
    );
  }

  /**
   * Combine the `text` field of each result into a single newline-separated string.
   * @param results - The Dakera text query results.
   * @returns The combined text.
   */
  private combineRetrievalResults(results: Array<{ text?: string }>): string {
    return results
      .filter((result) => result && typeof result.text === "string")
      .map((result) => result.text as string)
      .join("\n");
  }
}
