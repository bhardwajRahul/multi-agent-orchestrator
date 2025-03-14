import pytest
from unittest.mock import Mock, AsyncMock, patch
from typing import AsyncIterable
from multi_agent_orchestrator.types import ConversationMessage, ParticipantRole, AgentProviderType
from multi_agent_orchestrator.agents import (
    BedrockLLMAgent,
    BedrockLLMAgentOptions,
    AgentStreamResponse)
from multi_agent_orchestrator.utils import Logger, AgentTools, AgentTool
from multi_agent_orchestrator.retrievers import Retriever


logger = Logger()

@pytest.fixture
def mock_boto3_client():
    with patch('boto3.client') as mock_client:
        yield mock_client

@pytest.fixture
def bedrock_llm_agent(mock_boto3_client):
    options = BedrockLLMAgentOptions(
        name="TestAgent",
        description="A test agent",
        model_id="test-model",
        region="us-west-2",
        streaming=False,
        inference_config={
            'maxTokens': 500,
            'temperature': 0.5,
            'topP': 0.8,
            'stopSequences': []
        },
        guardrail_config={
        'guardrailIdentifier': 'myGuardrailIdentifier',
        'guardrailVersion': 'myGuardrailVersion',
        'trace': 'enabled'
    }
    )
    agent = BedrockLLMAgent(options)
    yield agent
    mock_boto3_client.reset_mock()


def test_no_region_init(bedrock_llm_agent, mock_boto3_client):
    mock_boto3_client.reset_mock()
    options = BedrockLLMAgentOptions(
        name="TestAgent",
        description="A test agent",
    )

    _bedrock_llm_agent = BedrockLLMAgent(options)
    mock_boto3_client.assert_called_once_with('bedrock-runtime')

def test_custom_system_prompt_with_variable(bedrock_llm_agent, mock_boto3_client):
    options = BedrockLLMAgentOptions(
        name="TestAgent",
        description="A test agent",
        custom_system_prompt={
            'template': """This is my new prompt with this {{variable}}""",
            'variables': {'variable': 'value'}
        }
    )

    _bedrock_llm_agent = BedrockLLMAgent(options)
    assert(_bedrock_llm_agent.system_prompt == 'This is my new prompt with this value')


def test_custom_system_prompt_with_wrong_variable(bedrock_llm_agent, mock_boto3_client):
    options = BedrockLLMAgentOptions(
        name="TestAgent",
        description="A test agent",
        custom_system_prompt={
            'template': """This is my new prompt with this {{variable}}""",
            'variables': {'variableT': 'value'}
        }
    )

    _bedrock_llm_agent = BedrockLLMAgent(options)
    assert(_bedrock_llm_agent.system_prompt == 'This is my new prompt with this {{variable}}')


@pytest.mark.asyncio
async def test_process_request_single_response(bedrock_llm_agent, mock_boto3_client):
    mock_response = {
        'output': {
            'message': {
                'role': 'assistant',
                'content': [{'text': 'This is a test response'}]
            }
        }
    }
    mock_boto3_client.return_value.converse.return_value = mock_response

    input_text = "Test question"
    user_id = "test_user"
    session_id = "test_session"
    chat_history = []

    result = await bedrock_llm_agent.process_request(input_text, user_id, session_id, chat_history)

    assert isinstance(result, ConversationMessage)
    assert result.role == ParticipantRole.ASSISTANT.value
    assert result.content[0]['text'] == 'This is a test response'


@pytest.mark.asyncio
async def test_process_request_streaming(bedrock_llm_agent, mock_boto3_client):
    bedrock_llm_agent.streaming = True
    mock_stream_response = {
        "stream": [
            {"messageStart": {"role": "assistant"}},
            {"contentBlockDelta": {"delta": {"text": "This "}}},
            {"contentBlockDelta": {"delta": {"text": "is "}}},
            {"contentBlockDelta": {"delta": {"text": "a "}}},
            {"contentBlockDelta": {"delta": {"text": "test "}}},
            {"contentBlockDelta": {"delta": {"text": "response"}}},
            {"contentBlockStop"}
        ]
    }
    mock_boto3_client.return_value.converse_stream.return_value = mock_stream_response

    input_text = "Test question"
    user_id = "test_user"
    session_id = "test_session"
    chat_history = []

    result = await bedrock_llm_agent.process_request(input_text, user_id, session_id, chat_history)

    assert isinstance(result, AsyncIterable)

    async for chunk in result:
        assert isinstance(chunk, AgentStreamResponse)
        if chunk.final_message:
            assert chunk.final_message.role == ParticipantRole.ASSISTANT.value
            assert chunk.final_message.content[0]['text'] == 'This is a test response'


@pytest.mark.asyncio
async def test_process_request_with_tool_use(bedrock_llm_agent, mock_boto3_client):
    async def _handler(message, conversation):
        return ConversationMessage(role=ParticipantRole.ASSISTANT, content=[{'text': 'Tool response'}])
    bedrock_llm_agent.tool_config = {
        "tool": [
            AgentTool(name='test_tool', func=_handler, description='This is a test handler')
        ],
        "toolMaxRecursions": 2,
        "useToolHandler": AsyncMock()
    }

    mock_responses = [
        {
            'output': {
                'message': {
                    'role': 'assistant',
                    'content': [{'toolUse': {'name': 'test_tool'}}]
                }
            }
        },
        {
            'output': {
                'message': {
                    'role': 'assistant',
                    'content': [{'text': 'Final response'}]
                }
            }
        }
    ]
    mock_boto3_client.return_value.converse.side_effect = mock_responses

    input_text = "Test question"
    user_id = "test_user"
    session_id = "test_session"
    chat_history = []

    result = await bedrock_llm_agent.process_request(input_text, user_id, session_id, chat_history)

    assert isinstance(result, ConversationMessage)
    assert result.role == ParticipantRole.ASSISTANT.value
    assert result.content[0]['text'] == 'Final response'
    assert bedrock_llm_agent.tool_config['useToolHandler'].call_count == 1

def test_set_system_prompt(bedrock_llm_agent):
    new_template = "You are a {{role}}. Your task is {{task}}."
    variables = {"role": "test agent", "task": "to run tests"}

    bedrock_llm_agent.set_system_prompt(new_template, variables)

    assert bedrock_llm_agent.prompt_template == new_template
    assert bedrock_llm_agent.custom_variables == variables
    assert bedrock_llm_agent.system_prompt == "You are a test agent. Your task is to run tests."

def test_streaming(mock_boto3_client):
    options = BedrockLLMAgentOptions(
        name="TestAgent",
        description="A test agent",
        custom_system_prompt={
            'template': """This is my new prompt with this {{variable}}""",
            'variables': {'variable': 'value'}
        },
        streaming=True
    )

    agent = BedrockLLMAgent(options)
    assert(agent.is_streaming_enabled() == True)

    options = BedrockLLMAgentOptions(
        name="TestAgent",
        description="A test agent",
        custom_system_prompt={
            'template': """This is my new prompt with this {{variable}}""",
            'variables': {'variable': 'value'}
        },
        streaming=False
    )

    agent = BedrockLLMAgent(options)
    assert(agent.is_streaming_enabled() == False)

    options = BedrockLLMAgentOptions(
        name="TestAgent",
        description="A test agent",
        custom_system_prompt={
            'template': """This is my new prompt with this {{variable}}""",
            'variables': {'variable': 'value'}
        }
    )

    agent = BedrockLLMAgent(options)
    assert(agent.is_streaming_enabled() == False)


@pytest.mark.asyncio
async def test_prepare_system_prompt_with_retriever(bedrock_llm_agent):
    # Create a mock retriever
    mock_retriever = AsyncMock(spec=Retriever)
    mock_retriever.retrieve_and_combine_results.return_value = "Retrieved context"

    # Update the agent with the retriever
    bedrock_llm_agent.retriever = mock_retriever

    # Call the method
    system_prompt = await bedrock_llm_agent._prepare_system_prompt("Test input")

    # Verify the result and the retriever call
    assert "Retrieved context" in system_prompt
    mock_retriever.retrieve_and_combine_results.assert_called_once_with("Test input")

def test_prepare_tool_config_with_agent_tools(bedrock_llm_agent):
    # Create mock AgentTools
    mock_agent_tools = Mock(spec=AgentTools)
    mock_agent_tools.to_bedrock_format.return_value = [{"name": "test_tool"}]

    # Set up the tool_config
    bedrock_llm_agent.tool_config = {"tool": mock_agent_tools}

    # Call the method
    result = bedrock_llm_agent._prepare_tool_config()

    # Verify the result
    assert result == {"tools": [{"name": "test_tool"}]}
    mock_agent_tools.to_bedrock_format.assert_called_once()

def test_prepare_tool_config_with_agent_tool_list(bedrock_llm_agent):
    # Create mock AgentTool
    mock_agent_tool = Mock(spec=AgentTool)
    mock_agent_tool.to_bedrock_format.return_value = {"name": "test_tool"}

    # Also include a non-AgentTool item
    direct_tool_dict = {"name": "direct_tool"}

    # Set up the tool_config
    bedrock_llm_agent.tool_config = {"tool": [mock_agent_tool, direct_tool_dict]}

    # Call the method
    result = bedrock_llm_agent._prepare_tool_config()

    # Verify the result
    assert result == {"tools": [{"name": "test_tool"}, {"name": "direct_tool"}]}
    mock_agent_tool.to_bedrock_format.assert_called_once()

def test_prepare_tool_config_with_invalid_config(bedrock_llm_agent):
    # Set up an invalid tool_config
    bedrock_llm_agent.tool_config = {"tool": "invalid"}

    # Call the method and check for exception
    with pytest.raises(RuntimeError, match="Invalid tool config"):
        bedrock_llm_agent._prepare_tool_config()


@pytest.mark.asyncio
async def test_handle_single_response_error(bedrock_llm_agent, mock_boto3_client):
    # Set up the mock to raise an exception
    mock_boto3_client.return_value.converse.side_effect = Exception("Test error")

    # Call the method and check for exception
    with pytest.raises(Exception, match="Test error"):
        await bedrock_llm_agent.handle_single_response({})

@pytest.mark.asyncio
async def test_handle_streaming_response_error(bedrock_llm_agent, mock_boto3_client):
    # Set up the mock to raise an exception
    mock_boto3_client.return_value.converse_stream.side_effect = Exception("Test error")

    # Call the method and check for exception
    with pytest.raises(Exception, match="Test error"):
        async for _ in bedrock_llm_agent.handle_streaming_response({}):
            pass


@pytest.mark.asyncio
async def test_process_tool_block_with_agent_tools(bedrock_llm_agent):
    # Create a mock AgentTools
    mock_agent_tools = AsyncMock(spec=AgentTools)
    expected_response = ConversationMessage(
        role=ParticipantRole.ASSISTANT.value,
        content=[{"text": "Tool response"}]
    )
    mock_agent_tools.tool_handler.return_value = expected_response

    # Set up the tool_config
    bedrock_llm_agent.tool_config = {"tool": mock_agent_tools}

    # Create a test LLM response with toolUse
    llm_response = ConversationMessage(
        role=ParticipantRole.ASSISTANT.value,
        content=[{"toolUse": {"name": "test_tool", "input": {"param": "value"}}}]
    )

    # Call the method
    result = await bedrock_llm_agent._process_tool_block(llm_response, [])

    # Verify the result
    assert result == expected_response
    mock_agent_tools.tool_handler.assert_called_once_with(
        AgentProviderType.BEDROCK.value, llm_response, []
    )

@pytest.mark.asyncio
async def test_process_tool_block_with_invalid_tool(bedrock_llm_agent):
    # Set up an invalid tool configuration
    bedrock_llm_agent.tool_config = {"tool": "invalid"}

    # Create a test LLM response with toolUse
    llm_response = ConversationMessage(
        role=ParticipantRole.ASSISTANT.value,
        content=[{"toolUse": {"name": "test_tool", "input": {"param": "value"}}}]
    )

    # Call the method and check for exception
    with pytest.raises(ValueError, match="You must use AgentTools class"):
        await bedrock_llm_agent._process_tool_block(llm_response, [])


@pytest.mark.asyncio
async def test_handle_streaming_with_tool_use(bedrock_llm_agent, mock_boto3_client):
    # Enable streaming
    bedrock_llm_agent.streaming = True

    # Set up the tool handler
    async def mock_tool_handler(message, conversation):
        return ConversationMessage(
            role=ParticipantRole.ASSISTANT.value,
            content=[{"text": "Tool response"}]
        )

    bedrock_llm_agent.tool_config = {
        "tool": AgentTools(tools=[]),
        "useToolHandler": mock_tool_handler
    }

    # First response with tool use
    stream_response1 = {
        "stream": [
            {"messageStart": {"role": "assistant"}},
            {"contentBlockStart": {"start": {"toolUse": {"toolUseId": "123", "name": "test_tool"}}}},
            {"contentBlockDelta": {"delta": {"toolUse": {"input": "{\"param\":"}}}},
            {"contentBlockDelta": {"delta": {"toolUse": {"input": "\"value\"}"}}}},
            {"contentBlockStop": {}}
        ]
    }

    # Second response after tool use
    stream_response2 = {
        "stream": [
            {"messageStart": {"role": "assistant"}},
            {"contentBlockDelta": {"delta": {"text": "Final"}}},
            {"contentBlockDelta": {"delta": {"text": " response"}}},
            {"contentBlockStop": {}}
        ]
    }

    mock_boto3_client.return_value.converse_stream.side_effect = [stream_response1, stream_response2]

    # Call the method
    input_text = "Test with tool"
    user_id = "test_user"
    session_id = "test_session"
    chat_history = []

    result = await bedrock_llm_agent.process_request(input_text, user_id, session_id, chat_history)

    # Verify it's an AsyncIterable
    assert isinstance(result, AsyncIterable)

    # Collect all chunks
    chunks = []
    async for chunk in result:
        chunks.append(chunk)

    # Verify we get the expected number of chunks
    assert len(chunks) > 0

    # Verify the final message in the last chunk
    final_chunks = [chunk for chunk in chunks if chunk.final_message is not None]
    assert len(final_chunks) > 0

    # Verify converse_stream was called twice (first for tool use, then for final response)
    assert mock_boto3_client.return_value.converse_stream.call_count == 2

@pytest.mark.asyncio
async def test_handle_single_response_no_output(bedrock_llm_agent, mock_boto3_client):
    # Set up mock to return response with no output
    mock_boto3_client.return_value.converse.return_value = {"not_output": {}}

    # Call the method and check for exception
    with pytest.raises(ValueError, match="No output received from Bedrock model"):
        await bedrock_llm_agent.handle_single_response({})

@pytest.mark.asyncio
async def test_handle_streaming_with_text_response(bedrock_llm_agent, mock_boto3_client):
    # Set up stream response with only text content
    stream_response = {
        "stream": [
            {"messageStart": {"role": "assistant"}},
            {"contentBlockDelta": {"delta": {"text": "This "}}},
            {"contentBlockDelta": {"delta": {"text": "is "}}},
            {"contentBlockDelta": {"delta": {"text": "a "}}},
            {"contentBlockStop": {}}
        ]
    }

    mock_boto3_client.return_value.converse_stream.return_value = stream_response

    # Initialize callbacks
    bedrock_llm_agent.callbacks = Mock()

    # Call the method
    chunks = []
    async for chunk in bedrock_llm_agent.handle_streaming_response({}):
        chunks.append(chunk)

    # Verify we got the expected chunks
    assert len(chunks) == 4  # 3 text chunks + final message

    # Verify callbacks were called for each text chunk
    assert bedrock_llm_agent.callbacks.on_llm_new_token.call_count == 3

    # Verify the last chunk has the final message
    assert chunks[-1].final_message is not None
    assert chunks[-1].final_message.role == ParticipantRole.ASSISTANT.value
    assert chunks[-1].final_message.content[0]["text"] == "This is a "

@pytest.mark.asyncio
async def test_get_max_recursions(bedrock_llm_agent):
    # Test without tool config
    bedrock_llm_agent.tool_config = None
    assert bedrock_llm_agent._get_max_recursions() == 1

    # Test with tool config but without toolMaxRecursions
    bedrock_llm_agent.tool_config = {"tool": Mock()}
    assert bedrock_llm_agent._get_max_recursions() == bedrock_llm_agent.default_max_recursions

    # Test with tool config and custom toolMaxRecursions
    bedrock_llm_agent.tool_config = {"tool": Mock(), "toolMaxRecursions": 5}
    assert bedrock_llm_agent._get_max_recursions() == 5


@pytest.fixture
def client_fixture():
    # Create a mock client
    mock_client = Mock()
    return mock_client

def test_client_provided(client_fixture):
    # Test initialization with provided client
    options = BedrockLLMAgentOptions(
        name="TestAgent",
        description="A test agent",
        client=client_fixture
    )

    agent = BedrockLLMAgent(options)
    assert agent.client is client_fixture