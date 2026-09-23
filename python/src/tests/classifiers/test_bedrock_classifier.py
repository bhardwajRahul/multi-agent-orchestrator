import boto3
import pytest
from botocore.stub import Stubber

from agent_squad.agents import Agent, AgentOptions
from agent_squad.classifiers import BedrockClassifier, BedrockClassifierOptions


class MockAgent(Agent):
    async def process_request(self, *args, **kwargs):
        raise NotImplementedError


@pytest.mark.asyncio
async def test_converse_request_passes_botocore_validation():
    # Stubber validates parameters like the real client, so extra keys on the
    # message (e.g. ConversationMessage.citations) would fail here.
    client = boto3.client(
        'bedrock-runtime',
        region_name='us-east-1',
        aws_access_key_id='test',
        aws_secret_access_key='test',
    )
    classifier = BedrockClassifier(BedrockClassifierOptions(
        model_id='anthropic.claude-test', client=client))
    agent = MockAgent(AgentOptions(name='Billing Agent', description='Handles billing'))
    classifier.set_agents({agent.id: agent})

    with Stubber(client) as stubber:
        stubber.add_response('converse', {
            'output': {'message': {'role': 'assistant', 'content': [{'toolUse': {
                'toolUseId': 'tool-1',
                'name': 'analyzePrompt',
                'input': {'userinput': 'refund', 'selected_agent': 'billing-agent', 'confidence': 0.8},
            }}]}},
            'stopReason': 'tool_use',
            'usage': {'inputTokens': 10, 'outputTokens': 5, 'totalTokens': 15},
            'metrics': {'latencyMs': 1},
        })

        result = await classifier.classify('I want a refund', [])

    assert result.selected_agent is agent
    assert result.confidence == 0.8
