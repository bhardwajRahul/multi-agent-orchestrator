import io
import json
import urllib.error
from email.message import Message
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from agent_squad.classifiers import ClassifierResult
from agent_squad.classifiers.jev_classifier import (
    DEFAULT_INSTRUCTIONS,
    JEV_DECISION_API_URL,
    JEV_MODEL_ID_LATEST,
    JevClassifier,
    JevClassifierOptions,
)
from agent_squad.types import ConversationMessage, ParticipantRole
from agent_squad.agents import Agent


class MockAgent(Agent):
    """Mock agent for testing"""
    def __init__(self, agent_id, description="Test agent"):
        super().__init__(type('MockOptions', (), {
            'name': agent_id,
            'description': description,
            'save_chat': True,
            'callbacks': None,
            'LOG_AGENT_DEBUG_TRACE': False
        })())
        self.id = agent_id
        self.description = description

    async def process_request(self, input_text, user_id, session_id, chat_history,
                              additional_params=None):
        return ConversationMessage(role="assistant",
                                   content=[{"text": f"Response from {self.id}"}])


def mock_agents():
    return {
        'test-agent': MockAgent('test-agent', 'A tech support agent'),
        'billing-agent': MockAgent('billing-agent', 'A billing agent'),
    }


def ok_response(payload):
    """Context-manager mock mimicking urllib.request.urlopen's response."""
    response = MagicMock()
    response.read.return_value = json.dumps(payload).encode("utf-8")
    manager = MagicMock()
    manager.__enter__.return_value = response
    manager.__exit__.return_value = False
    return manager


def http_error(code, reason, body="", retry_after=None):
    headers = Message()
    if retry_after is not None:
        headers["Retry-After"] = retry_after
    return urllib.error.HTTPError(
        url=JEV_DECISION_API_URL,
        code=code,
        msg=reason,
        hdrs=headers,
        fp=io.BytesIO(body.encode("utf-8")),
    )


CHOICE_PAYLOAD = {
    "answers": {
        "selected_agent": {"type": "choice", "choice": "billing-agent", "confidence": 0.91},
    },
    "usage": {"input_tokens": 420, "output_tokens": 60},
}


class TestJevClassifierOptions:

    def test_init_with_defaults(self):
        options = JevClassifierOptions()
        assert options.model_id is None
        assert options.api_key is None
        assert options.base_url is None
        assert options.instructions is None
        assert options.timeout == 30.0
        assert options.max_retries == 2

    def test_init_with_custom_values(self):
        options = JevClassifierOptions(
            model_id='jev-1.13.0',
            api_key='test',
            base_url='https://gateway.example.com/v1/systemone',
            instructions='custom instructions',
            timeout=5.0,
            max_retries=0,
        )
        assert options.model_id == 'jev-1.13.0'
        assert options.api_key == 'test'
        assert options.base_url == 'https://gateway.example.com/v1/systemone'
        assert options.instructions == 'custom instructions'
        assert options.timeout == 5.0
        assert options.max_retries == 0


class TestJevClassifier:

    def setup_method(self):
        self.classifier = JevClassifier(JevClassifierOptions(api_key='test-api-key'))

    def test_default_configuration(self):
        assert self.classifier.base_url == JEV_DECISION_API_URL
        assert self.classifier.model_id == JEV_MODEL_ID_LATEST
        assert self.classifier.instructions == DEFAULT_INSTRUCTIONS
        assert self.classifier.timeout == 30.0
        assert self.classifier.max_retries == 2

    def test_defaults_to_official_endpoint(self):
        assert JEV_DECISION_API_URL == 'https://api.typesafe.ai/v1/systemone'

    def test_custom_model_id(self):
        classifier = JevClassifier(JevClassifierOptions(
            api_key='test', model_id='jev-1.13.0'))
        assert classifier.model_id == 'jev-1.13.0'

    def test_api_key_falls_back_to_environment(self, monkeypatch):
        monkeypatch.setenv('TYPESAFE_API_KEY', 'from-env')
        classifier = JevClassifier()
        assert classifier.api_key == 'from-env'

    def test_explicit_api_key_takes_precedence(self, monkeypatch):
        monkeypatch.setenv('TYPESAFE_API_KEY', 'from-env')
        classifier = JevClassifier(JevClassifierOptions(api_key='explicit'))
        assert classifier.api_key == 'explicit'

    def test_missing_api_key_raises(self, monkeypatch):
        monkeypatch.delenv('TYPESAFE_API_KEY', raising=False)
        with pytest.raises(ValueError, match="Jev API key is required"):
            JevClassifier()

    @pytest.mark.asyncio
    async def test_sends_choice_question_built_from_agents(self):
        self.classifier.set_agents(mock_agents())

        with patch('urllib.request.urlopen', return_value=ok_response(CHOICE_PAYLOAD)) \
                as mock_urlopen:
            await self.classifier.classify('I was charged twice this month', [])

        assert mock_urlopen.call_count == 1
        request = mock_urlopen.call_args[0][0]
        assert mock_urlopen.call_args[1]['timeout'] == 30.0

        assert request.full_url == JEV_DECISION_API_URL
        assert request.get_method() == 'POST'
        assert request.get_header('Authorization') == 'Bearer test-api-key'
        assert request.get_header('Content-type') == 'application/json'

        body = json.loads(request.data.decode('utf-8'))
        assert body['model'] == JEV_MODEL_ID_LATEST
        assert 'I was charged twice this month' in body['state']
        assert body['questions']['selected_agent']['type'] == 'choice'
        assert body['questions']['selected_agent']['criteria'] == {
            'test-agent': 'A tech support agent',
            'billing-agent': 'A billing agent',
            'unknown': 'None of the other agents is a reasonable fit for this request.',
        }

    @pytest.mark.asyncio
    async def test_default_state_is_conversation_and_current_input(self):
        self.classifier.set_agents(mock_agents())
        history = [ConversationMessage(role=ParticipantRole.USER.value,
                                       content=[{"text": "My printer is offline"}])]

        with patch('urllib.request.urlopen', return_value=ok_response(CHOICE_PAYLOAD)) \
                as mock_urlopen:
            await self.classifier.classify('I was charged twice', history)

        body = json.loads(mock_urlopen.call_args[0][0].data.decode('utf-8'))
        assert body['state'] == (
            '<conversation_history>\nuser: My printer is offline\n</conversation_history>\n\n'
            '<current_user_input>\nI was charged twice\n</current_user_input>'
        )

    @pytest.mark.asyncio
    async def test_custom_system_prompt_is_used_as_state(self):
        self.classifier.set_agents(mock_agents())
        self.classifier.set_system_prompt('Custom: {{AGENT_DESCRIPTIONS}}')

        with patch('urllib.request.urlopen', return_value=ok_response(CHOICE_PAYLOAD)) \
                as mock_urlopen:
            await self.classifier.classify('input', [])

        body = json.loads(mock_urlopen.call_args[0][0].data.decode('utf-8'))
        assert 'Custom: test-agent:A tech support agent' in body['state']

    @pytest.mark.asyncio
    async def test_agent_id_colliding_with_unknown_raises(self):
        self.classifier.set_agents({'unknown': MockAgent('unknown', 'Catch-all agent')})

        with patch('urllib.request.urlopen') as mock_urlopen:
            with pytest.raises(ValueError, match='The agent id "unknown" is reserved'):
                await self.classifier.process_request('input', [])
        mock_urlopen.assert_not_called()

    @pytest.mark.asyncio
    async def test_resolves_choice_to_agent(self):
        self.classifier.set_agents(mock_agents())

        with patch('urllib.request.urlopen', return_value=ok_response(CHOICE_PAYLOAD)):
            result = await self.classifier.process_request('input', [])

        assert isinstance(result, ClassifierResult)
        assert result.selected_agent.id == 'billing-agent'
        assert result.confidence == 0.91

    @pytest.mark.asyncio
    async def test_exposes_usage_and_full_response(self):
        self.classifier.set_agents(mock_agents())
        assert self.classifier.get_last_usage() is None
        assert self.classifier.get_last_response() is None

        with patch('urllib.request.urlopen', return_value=ok_response(CHOICE_PAYLOAD)):
            await self.classifier.process_request('input', [])

        assert self.classifier.get_last_usage() == {"input_tokens": 420, "output_tokens": 60}
        assert self.classifier.get_last_response() == CHOICE_PAYLOAD

    @pytest.mark.asyncio
    async def test_unknown_choice_returns_no_agent(self):
        self.classifier.set_agents(mock_agents())
        payload = {
            "answers": {
                "selected_agent": {"type": "choice", "choice": "unknown", "confidence": 0.32},
            },
        }

        with patch('urllib.request.urlopen', return_value=ok_response(payload)):
            result = await self.classifier.process_request('input', [])

        assert result.selected_agent is None
        assert result.confidence == 0.32

    @pytest.mark.asyncio
    async def test_no_agents_registered_raises_before_network_call(self):
        with patch('urllib.request.urlopen') as mock_urlopen:
            with pytest.raises(ValueError, match="No agents registered"):
                await self.classifier.process_request('input', [])
        mock_urlopen.assert_not_called()

    @pytest.mark.asyncio
    async def test_malformed_answer_raises(self):
        self.classifier.set_agents(mock_agents())
        payload = {"answers": {"selected_agent": {"type": "choice", "invalid_key": "oops"}}}

        with patch('urllib.request.urlopen', return_value=ok_response(payload)):
            with pytest.raises(ValueError,
                               match="No valid 'selected_agent' choice answer"):
                await self.classifier.process_request('input', [])


    @pytest.mark.asyncio
    async def test_other_http_errors_include_status_and_body(self):
        self.classifier.set_agents(mock_agents())

        with patch('urllib.request.urlopen',
                   side_effect=http_error(401, 'Unauthorized', 'invalid key')):
            with pytest.raises(ValueError,
                               match="Jev request failed: 401 Unauthorized - invalid key"):
                await self.classifier.process_request('input', [])

    @pytest.mark.asyncio
    async def test_retries_rate_limited_and_overloaded_responses(self):
        self.classifier.set_agents(mock_agents())

        with patch('urllib.request.urlopen', side_effect=[
            http_error(429, 'Too Many Requests', retry_after='0'),
            http_error(529, 'Overloaded', retry_after='0'),
            ok_response(CHOICE_PAYLOAD),
        ]) as mock_urlopen:
            result = await self.classifier.process_request('input', [])

        assert mock_urlopen.call_count == 3
        assert result.selected_agent.id == 'billing-agent'

    @pytest.mark.asyncio
    async def test_gives_up_after_max_retries(self):
        self.classifier.set_agents(mock_agents())

        with patch('urllib.request.urlopen', side_effect=[
            http_error(429, 'Too Many Requests', 'slow down', retry_after='0') for _ in range(3)
        ]) as mock_urlopen:
            with pytest.raises(ValueError,
                               match="Jev request failed: 429 Too Many Requests - slow down"):
                await self.classifier.process_request('input', [])

        assert mock_urlopen.call_count == 3

    @pytest.mark.asyncio
    async def test_backs_off_exponentially_without_retry_after(self):
        self.classifier.set_agents(mock_agents())

        with patch('urllib.request.urlopen', side_effect=[
            http_error(503, 'Service Unavailable'),
            http_error(503, 'Service Unavailable'),
            ok_response(CHOICE_PAYLOAD),
        ]), patch('asyncio.sleep', new_callable=AsyncMock) as mock_sleep:
            await self.classifier.process_request('input', [])

        assert [c.args[0] for c in mock_sleep.call_args_list] == [0.5, 1.0]

    @pytest.mark.asyncio
    async def test_non_retryable_errors_are_not_retried(self):
        self.classifier.set_agents(mock_agents())

        with patch('urllib.request.urlopen',
                   side_effect=http_error(422, 'Unprocessable Entity')) as mock_urlopen:
            with pytest.raises(ValueError, match="422"):
                await self.classifier.process_request('input', [])

        assert mock_urlopen.call_count == 1

    @pytest.mark.asyncio
    async def test_network_errors_propagate(self):
        self.classifier.set_agents(mock_agents())

        with patch('urllib.request.urlopen',
                   side_effect=urllib.error.URLError('network down')):
            with pytest.raises(urllib.error.URLError):
                await self.classifier.process_request('input', [])

    @pytest.mark.asyncio
    async def test_timeout_raises_dedicated_message(self):
        self.classifier.set_agents(mock_agents())

        with patch('urllib.request.urlopen', side_effect=TimeoutError('timed out')):
            with pytest.raises(TimeoutError, match="Jev request timed out after 30.0s"):
                await self.classifier.process_request('input', [])

    @pytest.mark.asyncio
    async def test_url_error_wrapping_timeout_raises_dedicated_message(self):
        self.classifier.set_agents(mock_agents())

        with patch('urllib.request.urlopen',
                   side_effect=urllib.error.URLError(TimeoutError('timed out'))):
            with pytest.raises(TimeoutError, match="Jev request timed out after 30.0s"):
                await self.classifier.process_request('input', [])

    @pytest.mark.asyncio
    async def test_custom_base_url_and_timeout_are_used(self):
        classifier = JevClassifier(JevClassifierOptions(
            api_key='test',
            base_url='https://gateway.example.com/v1/systemone',
            timeout=5.0,
        ))
        classifier.set_agents(mock_agents())

        with patch('urllib.request.urlopen', return_value=ok_response(CHOICE_PAYLOAD)) \
                as mock_urlopen:
            await classifier.process_request('input', [])

        request = mock_urlopen.call_args[0][0]
        assert request.full_url == 'https://gateway.example.com/v1/systemone'
        assert mock_urlopen.call_args[1]['timeout'] == 5.0
