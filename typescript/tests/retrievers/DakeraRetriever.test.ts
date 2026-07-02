import { DakeraRetriever, DakeraRetrieverOptions } from '../../src/retrievers/DakeraRetriever';
import { DakeraClient } from '@dakera-ai/dakera';

jest.mock('@dakera-ai/dakera');

describe('DakeraRetriever', () => {
  const MockedDakeraClient = DakeraClient as jest.MockedClass<typeof DakeraClient>;
  let queryText: jest.Mock;

  beforeEach(() => {
    MockedDakeraClient.mockClear();
    queryText = jest.fn();
    MockedDakeraClient.mockImplementation(() => ({ queryText }) as unknown as DakeraClient);
    process.env.DAKERA_API_KEY = 'dk-fake';
    delete process.env.DAKERA_URL;
  });

  const make = (opts: Partial<DakeraRetrieverOptions> = {}) =>
    new DakeraRetriever({ namespace: 'docs', ...opts });

  test('constructor throws when namespace is missing', () => {
    expect(() => new DakeraRetriever({ namespace: '' } as DakeraRetrieverOptions)).toThrow(
      'namespace is required',
    );
  });

  test('constructor throws when apiKey is missing', () => {
    delete process.env.DAKERA_API_KEY;
    expect(() => new DakeraRetriever({ namespace: 'docs' })).toThrow('apiKey is required');
  });

  test('constructor uses DAKERA_URL and DAKERA_API_KEY env vars', () => {
    process.env.DAKERA_URL = 'http://env-host:9999';
    make();
    expect(MockedDakeraClient).toHaveBeenCalledWith({
      baseUrl: 'http://env-host:9999',
      apiKey: 'dk-fake',
    });
  });

  test('constructor defaults to localhost', () => {
    make();
    expect(MockedDakeraClient).toHaveBeenCalledWith({
      baseUrl: 'http://localhost:3000',
      apiKey: 'dk-fake',
    });
  });

  test('retrieve queries Dakera and returns results', async () => {
    queryText.mockResolvedValue({ results: [{ id: 'a', score: 0.9, text: 'alpha' }] });
    const retriever = make({ topK: 5, filter: { lang: { $eq: 'en' } } });

    const results = await retriever.retrieve('hello');

    expect(queryText).toHaveBeenCalledWith('docs', 'hello', {
      topK: 5,
      filter: { lang: { $eq: 'en' } },
    });
    expect(results[0].text).toBe('alpha');
  });

  test('retrieve throws on empty text', async () => {
    const retriever = make();
    await expect(retriever.retrieve('')).rejects.toThrow('Input text is required');
  });

  test('retrieveAndCombineResults joins text and skips results without text', async () => {
    queryText.mockResolvedValue({
      results: [{ id: 'a', text: 'alpha' }, { id: 'b', text: 'beta' }, { id: 'c' }],
    });
    const retriever = make();
    const combined = await retriever.retrieveAndCombineResults('q');
    expect(combined).toBe('alpha\nbeta');
  });

  test('retrieveAndGenerate is not supported', async () => {
    const retriever = make();
    await expect(retriever.retrieveAndGenerate('q')).rejects.toThrow(
      'does not support retrieveAndGenerate',
    );
  });
});
