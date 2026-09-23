import asyncio
import json
import os
import urllib.error
import urllib.request
from typing import Any, List, Optional

from agent_squad.types import ConversationMessage
from agent_squad.utils.logger import Logger
from agent_squad.classifiers import Classifier, ClassifierResult, ClassifierCallbacks

# Official TypeSafe System One endpoint: https://docs.typesafe.ai/api
JEV_DECISION_API_URL = "https://api.typesafe.ai/v1/systemone"
JEV_MODEL_ID_LATEST = "jev-latest"

# Environment variable read when no api_key is passed, as in the official TypeSafe SDKs.
API_KEY_ENV_VAR = "TYPESAFE_API_KEY"

# The label offered to Jev when none of the registered agents fit the request.
# It is deliberately not a valid agent id, so get_agent_by_id resolves it to None.
UNKNOWN_AGENT_LABEL = "unknown"

# Jev's `choice` decision type accepts at most 255 labelled options.
MAX_CHOICE_CRITERIA = 255

# Statuses retried with backoff, matching the official SDKs' default policy:
# 408, 429 (rate limited) and 5xx (including 529 Overloaded).
RETRYABLE_STATUSES = frozenset({408, 429, *range(500, 600)})
BACKOFF_INITIAL_SECONDS = 0.5
BACKOFF_MAX_SECONDS = 5.0

DEFAULT_INSTRUCTIONS = f"""Select the single agent best equipped to handle the current user input.

The input may be a follow-up (e.g. "yes", "ok", "tell me more", "1"). Follow-ups answer a pending \
question or proposal in the conversation, which is not necessarily in the most recent turn: an agent \
may have asked something, the user switched topics to another agent, and is only now answering the \
earlier question. Select the agent whose pending question or proposal the input responds to.

If none of the agents is a reasonable fit, select "{UNKNOWN_AGENT_LABEL}"."""

# The agent descriptions already travel as the choice criteria, so the state
# only carries the conversation. Jev loses accuracy on large states full of
# unrelated detail, which rules out the base class's LLM-oriented prompt.
DEFAULT_PROMPT_TEMPLATE = """<conversation_history>
{{HISTORY}}
</conversation_history>"""


class JevClassifierOptions:
    def __init__(self,
                 model_id: Optional[str] = None,
                 api_key: Optional[str] = None,
                 base_url: Optional[str] = None,
                 instructions: Optional[str] = None,
                 timeout: float = 30.0,
                 max_retries: int = 2,
                 callbacks: Optional[ClassifierCallbacks] = None):
        # model_id: e.g. "jev-latest" or a pinned version like "jev-1.13.0".
        # Pin a version in production so decision thresholds don't shift.
        self.model_id = model_id
        # api_key falls back to the TYPESAFE_API_KEY environment variable when omitted.
        self.api_key = api_key
        # base_url can point at a gateway or a compatible endpoint, or at a stub in tests.
        self.base_url = base_url
        self.instructions = instructions
        # Seconds before each request attempt is aborted.
        self.timeout = timeout
        # Retries on 408, 429 and 5xx responses, with exponential backoff.
        self.max_retries = max_retries
        self.callbacks = callbacks or ClassifierCallbacks()


class JevClassifier(Classifier):
    """Classifier backed by the TypeSafe Jev System One API.

    Unlike the model-backed classifiers, Jev returns a typed decision rather
    than free text or a tool call: the registered agents are sent as the
    `criteria` of a `choice` question, and Jev replies with the winning label
    plus a calibrated confidence. The prompt template is used as the `state`
    the decision is made against, so custom system prompts keep working.
    """

    def __init__(self, options: Optional[JevClassifierOptions] = None):
        super().__init__()

        options = options or JevClassifierOptions()

        api_key = options.api_key or os.environ.get(API_KEY_ENV_VAR)
        if not api_key:
            raise ValueError(
                "Jev API key is required: pass options.api_key or set the "
                f"{API_KEY_ENV_VAR} environment variable"
            )

        self.api_key = api_key
        self.model_id = options.model_id or JEV_MODEL_ID_LATEST
        self.base_url = options.base_url or JEV_DECISION_API_URL
        self.instructions = options.instructions or DEFAULT_INSTRUCTIONS
        self.timeout = options.timeout
        self.max_retries = max(0, options.max_retries)
        self.callbacks = options.callbacks
        self.prompt_template = DEFAULT_PROMPT_TEMPLATE

        # Token usage reported by Jev for the most recent decision, if any.
        self._last_usage: Optional[dict[str, Any]] = None
        # Full parsed body of the most recent successful response, including
        # the versioned model id that answered.
        self._last_response: Optional[dict[str, Any]] = None

    def get_last_usage(self) -> Optional[dict[str, Any]]:
        """Token usage Jev reported for the most recent decision."""
        return self._last_usage

    def get_last_response(self) -> Optional[dict[str, Any]]:
        """Full parsed body of the most recent successful Jev response."""
        return self._last_response

    def _build_criteria(self) -> dict[str, str]:
        """Turns the registered agents into the criteria map of a `choice` question.

        Keys are agent ids, which is what get_agent_by_id expects back.
        """
        criteria = {agent.id: agent.description for agent in self.agents.values()}

        if not criteria:
            raise ValueError("No agents registered: call set_agents before classifying")

        if UNKNOWN_AGENT_LABEL in criteria:
            raise ValueError(
                f'The agent id "{UNKNOWN_AGENT_LABEL}" is reserved by JevClassifier; rename that agent'
            )

        criteria[UNKNOWN_AGENT_LABEL] = (
            "None of the other agents is a reasonable fit for this request."
        )

        if len(criteria) > MAX_CHOICE_CRITERIA:
            raise ValueError(
                f"Jev choice decisions support at most {MAX_CHOICE_CRITERIA} options, "
                f'including "{UNKNOWN_AGENT_LABEL}"; {len(criteria)} were provided'
            )

        return criteria

    @staticmethod
    def _is_choice_answer(answer: Any) -> bool:
        return (
            isinstance(answer, dict)
            and isinstance(answer.get("choice"), str)
            and isinstance(answer.get("confidence"), (int, float))
            and not isinstance(answer.get("confidence"), bool)
            and answer.get("type") in (None, "choice")
        )

    @staticmethod
    def _describe_http_error(error: urllib.error.HTTPError) -> str:
        try:
            detail = error.read().decode("utf-8")
        except Exception:
            detail = ""
        return (
            f"Jev request failed: {error.code} {error.reason}"
            + (f" - {detail}" if detail else "")
        )

    @staticmethod
    def _retry_delay(error: urllib.error.HTTPError, attempt: int) -> float:
        retry_after = error.headers.get("retry-after") if error.headers else None
        try:
            return max(0.0, float(retry_after))
        except (TypeError, ValueError):
            return min(BACKOFF_INITIAL_SECONDS * 2 ** attempt, BACKOFF_MAX_SECONDS)

    def _post(self, request: urllib.request.Request) -> Any:
        """Sends one request attempt. Blocking, so it runs in a worker thread."""
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return json.loads(response.read().decode("utf-8"))
        except TimeoutError as error:
            raise TimeoutError(f"Jev request timed out after {self.timeout}s") from error
        except urllib.error.HTTPError:
            raise
        except urllib.error.URLError as error:
            if isinstance(error.reason, TimeoutError):
                raise TimeoutError(f"Jev request timed out after {self.timeout}s") from error
            raise

    async def _send(self, request_body: dict[str, Any]) -> Any:
        request = urllib.request.Request(
            self.base_url,
            data=json.dumps(request_body).encode("utf-8"),
            headers={
                # The key is only ever sent in this header, never logged.
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            },
            method="POST",
        )

        attempt = 0
        while True:
            try:
                return await asyncio.to_thread(self._post, request)
            except urllib.error.HTTPError as error:
                if error.code in RETRYABLE_STATUSES and attempt < self.max_retries:
                    await asyncio.sleep(self._retry_delay(error, attempt))
                    attempt += 1
                    continue
                raise ValueError(self._describe_http_error(error)) from error

    async def process_request(self,
                              input_text: str,
                              chat_history: List[ConversationMessage]) -> ClassifierResult:
        request_body = {
            "model": self.model_id,
            # system_prompt holds the interpolated prompt template (the
            # conversation history by default); the current turn is appended
            # so the decision is made against the full context.
            "state": (
                f"{self.system_prompt}\n\n"
                f"<current_user_input>\n{input_text}\n</current_user_input>"
            ),
            "questions": {
                "selected_agent": {
                    "type": "choice",
                    "instructions": self.instructions,
                    "criteria": self._build_criteria(),
                },
            },
        }

        await self.callbacks.on_classifier_start(
            "JevClassifier", {"input_text": input_text, "chat_history": chat_history}
        )

        try:
            payload = await self._send(request_body)

            answers = payload.get("answers") if isinstance(payload, dict) else None
            answer = answers.get("selected_agent") if isinstance(answers, dict) else None

            if not self._is_choice_answer(answer):
                raise ValueError(
                    "No valid 'selected_agent' choice answer found in the Jev response"
                )

            self._last_response = payload
            self._last_usage = payload.get("usage")

            selected_agent = (
                None if answer["choice"] == UNKNOWN_AGENT_LABEL
                else self.get_agent_by_id(answer["choice"])
            )
            intent_classifier_result = ClassifierResult(
                selected_agent=selected_agent,
                confidence=float(answer["confidence"]),
            )

            await self.callbacks.on_classifier_stop(
                "JevClassifier",
                intent_classifier_result,
                usage=self._last_usage,
            )

            return intent_classifier_result

        except Exception as error:
            Logger.error(f"Error processing request:{str(error)}")
            raise error
