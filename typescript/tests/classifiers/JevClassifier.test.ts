import { JevClassifier, JevClassifierOptions } from '../../src/classifiers/jevClassifier';
import {
    ConversationMessage,
    JEV_DECISION_API_URL,
    JEV_MODEL_ID_LATEST,
    ParticipantRole,
} from '../../src/types';
import { MockAgent } from '../mock/mockAgent';

describe('JevClassifier', () => {
    let classifier: JevClassifier;
    let mockFetch: jest.Mock;

    const defaultOptions: JevClassifierOptions = {
        apiKey: 'test-api-key',
    };

    const mockAgents = () => ({
        'test-agent': new MockAgent({
            name: 'test-agent',
            description: 'A tech support agent',
        }),
        'billing-agent': new MockAgent({
            name: 'billing-agent',
            description: 'A billing agent',
        }),
    });

    const okResponse = (payload: unknown) => ({
        ok: true,
        status: 200,
        statusText: 'OK',
        json: jest.fn().mockResolvedValue(payload),
    });

    const errorResponse = (status: number, statusText: string, body = '', retryAfter?: string) => ({
        ok: false,
        status,
        statusText,
        headers: { get: (name: string) => (name === 'retry-after' ? retryAfter ?? null : null) },
        text: jest.fn().mockResolvedValue(body),
    });

    const choicePayload = {
        answers: {
            selected_agent: { type: 'choice', choice: 'billing-agent', confidence: 0.91 },
        },
    };

    beforeEach(() => {
        mockFetch = jest.fn();
        global.fetch = mockFetch as unknown as typeof fetch;
        classifier = new JevClassifier(defaultOptions);
    });

    afterEach(() => {
        jest.clearAllMocks();
        delete process.env.TYPESAFE_API_KEY;
    });

    describe('constructor', () => {
        it('should create an instance with default options', () => {
            expect(classifier).toBeInstanceOf(JevClassifier);
            expect(classifier['baseUrl']).toBe(JEV_DECISION_API_URL);
            expect(classifier['modelId']).toBe(JEV_MODEL_ID_LATEST);
            expect(classifier['timeoutMs']).toBe(30000);
            expect(classifier['maxRetries']).toBe(2);
        });

        it('should default to the official TypeSafe endpoint', () => {
            expect(JEV_DECISION_API_URL).toBe('https://api.typesafe.ai/v1/systemone');
        });

        it('should use a custom model ID if provided', () => {
            const customClassifier = new JevClassifier({
                ...defaultOptions,
                modelId: 'jev-1.13.0',
            });
            expect(customClassifier['modelId']).toBe('jev-1.13.0');
        });

        it('should fall back to the TYPESAFE_API_KEY environment variable', () => {
            process.env.TYPESAFE_API_KEY = 'from-env';
            const envClassifier = new JevClassifier();
            expect(envClassifier['apiKey']).toBe('from-env');
        });

        it('should prefer an explicit API key over the environment variable', () => {
            process.env.TYPESAFE_API_KEY = 'from-env';
            const explicitClassifier = new JevClassifier({ apiKey: 'explicit' });
            expect(explicitClassifier['apiKey']).toBe('explicit');
        });

        it('should throw an error if no API key is available', () => {
            expect(() => new JevClassifier()).toThrow(
                'Jev API key is required: pass options.apiKey or set the TYPESAFE_API_KEY environment variable'
            );
        });

        it('should use a custom base URL, instructions and timeout if provided', () => {
            const customClassifier = new JevClassifier({
                ...defaultOptions,
                baseUrl: 'https://gateway.example.com/v1/systemone',
                instructions: 'custom instructions',
                timeoutMs: 5000,
                maxRetries: 0,
            });
            expect(customClassifier['baseUrl']).toBe('https://gateway.example.com/v1/systemone');
            expect(customClassifier['instructions']).toBe('custom instructions');
            expect(customClassifier['timeoutMs']).toBe(5000);
            expect(customClassifier['maxRetries']).toBe(0);
        });
    });

    describe('processRequest', () => {
        const inputText = 'I was charged twice this month';
        const chatHistory: ConversationMessage[] = [];

        it('should send a choice question built from the registered agents', async () => {
            classifier.setAgents(mockAgents());
            mockFetch.mockResolvedValue(
                okResponse({
                    answers: {
                        selected_agent: { type: 'choice', choice: 'billing-agent', confidence: 0.91 },
                    },
                })
            );

            await classifier.classify(inputText, chatHistory);

            expect(mockFetch).toHaveBeenCalledTimes(1);
            const [url, init] = mockFetch.mock.calls[0];

            expect(url).toBe(JEV_DECISION_API_URL);
            expect(init.method).toBe('POST');
            expect(init.headers).toEqual({
                Authorization: 'Bearer test-api-key',
                'Content-Type': 'application/json',
            });

            const body = JSON.parse(init.body);
            expect(body.model).toBe(JEV_MODEL_ID_LATEST);
            expect(body.state).toContain(inputText);
            expect(body.questions.selected_agent.type).toBe('choice');
            expect(body.questions.selected_agent.criteria).toEqual({
                'test-agent': 'A tech support agent',
                'billing-agent': 'A billing agent',
                unknown: 'None of the other agents is a reasonable fit for this request.',
            });
        });

        it('should send only the conversation and current input as state by default', async () => {
            classifier.setAgents(mockAgents());
            mockFetch.mockResolvedValue(okResponse(choicePayload));
            const history: ConversationMessage[] = [
                { role: ParticipantRole.USER, content: [{ text: 'My printer is offline' }] },
            ];

            await classifier.classify(inputText, history);

            const body = JSON.parse(mockFetch.mock.calls[0][1].body);
            expect(body.state).toBe(
                '<conversation_history>\nuser: My printer is offline\n</conversation_history>\n\n' +
                    `<current_user_input>\n${inputText}\n</current_user_input>`
            );
        });

        it('should use a custom system prompt as state', async () => {
            classifier.setAgents(mockAgents());
            classifier.setSystemPrompt('Custom: {{AGENT_DESCRIPTIONS}}');
            mockFetch.mockResolvedValue(okResponse(choicePayload));

            await classifier.classify(inputText, chatHistory);

            const body = JSON.parse(mockFetch.mock.calls[0][1].body);
            expect(body.state).toContain('Custom: test-agent:A tech support agent');
        });

        it('should reject an agent whose id collides with "unknown"', async () => {
            classifier.setAgents({
                unknown: new MockAgent({ name: 'unknown', description: 'Catch-all agent' }),
            });

            await expect(classifier.processRequest(inputText, chatHistory))
                .rejects.toThrow('The agent id "unknown" is reserved by JevClassifier; rename that agent');
            expect(mockFetch).not.toHaveBeenCalled();
        });

        it('should resolve the chosen label to an agent', async () => {
            classifier.setAgents(mockAgents());
            mockFetch.mockResolvedValue(
                okResponse({
                    answers: {
                        selected_agent: { type: 'choice', choice: 'billing-agent', confidence: 0.91 },
                    },
                    usage: { input_tokens: 420, output_tokens: 20 },
                })
            );

            const result = await classifier.processRequest(inputText, chatHistory);

            expect(result).toEqual({
                selectedAgent: expect.any(MockAgent),
                confidence: 0.91,
            });
            expect(result.selectedAgent.id).toBe('billing-agent');
        });

        it('should expose the usage reported by Jev', async () => {
            const usage = { input_tokens: 420, output_tokens: 20 };
            classifier.setAgents(mockAgents());
            mockFetch.mockResolvedValue(
                okResponse({
                    answers: {
                        selected_agent: { type: 'choice', choice: 'billing-agent', confidence: 0.91 },
                    },
                    usage,
                })
            );

            expect(classifier.getLastUsage()).toBeUndefined();
            await classifier.processRequest(inputText, chatHistory);
            expect(classifier.getLastUsage()).toEqual(usage);
        });

        it('should expose the full response body', async () => {
            const payload = {
                model: 'jev-1.13.0',
                answers: {
                    selected_agent: { type: 'choice', choice: 'billing-agent', confidence: 0.91 },
                },
                usage: { input_tokens: 420, output_tokens: 20 },
            };
            classifier.setAgents(mockAgents());
            mockFetch.mockResolvedValue(okResponse(payload));

            expect(classifier.getLastResponse()).toBeUndefined();
            await classifier.processRequest(inputText, chatHistory);
            expect(classifier.getLastResponse()).toEqual(payload);
        });

        it('should return a null agent when Jev selects "unknown"', async () => {
            classifier.setAgents(mockAgents());
            mockFetch.mockResolvedValue(
                okResponse({
                    answers: {
                        selected_agent: { type: 'choice', choice: 'unknown', confidence: 0.32 },
                    },
                })
            );

            const result = await classifier.processRequest(inputText, chatHistory);

            expect(result).toEqual({ selectedAgent: null, confidence: 0.32 });
        });

        it('should throw an error if no agents have been registered', async () => {
            await expect(classifier.processRequest(inputText, chatHistory))
                .rejects.toThrow('No agents registered: call setAgents before classifying');
            expect(mockFetch).not.toHaveBeenCalled();
        });

        it('should throw an error if the answer does not match the expected structure', async () => {
            classifier.setAgents(mockAgents());
            mockFetch.mockResolvedValue(
                okResponse({ answers: { selected_agent: { type: 'choice', invalidKey: 'oops' } } })
            );

            await expect(classifier.processRequest(inputText, chatHistory))
                .rejects.toThrow("No valid 'selected_agent' choice answer found in the Jev response");
        });


        it('should include the status and body for other HTTP errors', async () => {
            classifier.setAgents(mockAgents());
            mockFetch.mockResolvedValue(errorResponse(401, 'Unauthorized', 'invalid key'));

            await expect(classifier.processRequest(inputText, chatHistory))
                .rejects.toThrow('Jev request failed: 401 Unauthorized - invalid key');
            expect(mockFetch).toHaveBeenCalledTimes(1);
        });

        it('should retry rate-limited and overloaded responses', async () => {
            classifier.setAgents(mockAgents());
            mockFetch
                .mockResolvedValueOnce(errorResponse(429, 'Too Many Requests', '', '0'))
                .mockResolvedValueOnce(errorResponse(529, 'Overloaded', '', '0'))
                .mockResolvedValueOnce(okResponse(choicePayload));

            const result = await classifier.processRequest(inputText, chatHistory);

            expect(mockFetch).toHaveBeenCalledTimes(3);
            expect(result.selectedAgent.id).toBe('billing-agent');
        });

        it('should give up after maxRetries retries', async () => {
            classifier.setAgents(mockAgents());
            mockFetch.mockResolvedValue(errorResponse(429, 'Too Many Requests', 'slow down', '0'));

            await expect(classifier.processRequest(inputText, chatHistory))
                .rejects.toThrow('Jev request failed: 429 Too Many Requests - slow down');
            expect(mockFetch).toHaveBeenCalledTimes(3);
        });

        it('should back off exponentially when no Retry-After header is sent', async () => {
            jest.useFakeTimers();
            try {
                classifier.setAgents(mockAgents());
                mockFetch
                    .mockResolvedValueOnce(errorResponse(503, 'Service Unavailable'))
                    .mockResolvedValueOnce(okResponse(choicePayload));

                const pending = classifier.processRequest(inputText, chatHistory);
                await jest.advanceTimersByTimeAsync(499);
                expect(mockFetch).toHaveBeenCalledTimes(1);
                await jest.advanceTimersByTimeAsync(1);
                await pending;
                expect(mockFetch).toHaveBeenCalledTimes(2);
            } finally {
                jest.useRealTimers();
            }
        });

        it('should throw an error if the request fails', async () => {
            classifier.setAgents(mockAgents());
            mockFetch.mockRejectedValue(new Error('network down'));

            await expect(classifier.processRequest(inputText, chatHistory))
                .rejects.toThrow('network down');
        });

        it('should throw a timeout error if the request is aborted', async () => {
            classifier.setAgents(mockAgents());
            const abortError = new Error('The operation was aborted');
            abortError.name = 'AbortError';
            mockFetch.mockRejectedValue(abortError);

            await expect(classifier.processRequest(inputText, chatHistory))
                .rejects.toThrow('Jev request timed out after 30000ms');
        });
    });
});
