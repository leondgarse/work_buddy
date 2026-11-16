"""OpenAI-compatible /chat/completions client (llama.cpp, Gemini, DeepSeek, …), standard library only."""
from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass

from .config import Provider

VISION_NAME_HINTS = ("vl", "vision", "gemini", "gpt-4o", "gpt-4.1", "gpt-5", "claude", "omni", "pixtral")


class LLMError(Exception):
    pass


@dataclass
class ModelInfo:
    id: str
    accepts_images: bool | None  # None when the server doesn't say


class Client:
    def __init__(self, provider: Provider, api_key: str | None = None, timeout: float = 900):
        self.provider = provider
        self.api_key = api_key if api_key is not None else provider.key()
        self.timeout = timeout

    def _request(self, path: str, body: dict | None = None) -> urllib.request.Request:
        url = self.provider.base_url.strip().rstrip("/") + path
        req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None,
                                     method="POST" if body is not None else "GET")
        req.add_header("Content-Type", "application/json")
        if self.api_key:
            req.add_header("Authorization", f"Bearer {self.api_key}")
        return req

    def list_models(self) -> list[ModelInfo]:
        try:
            with urllib.request.urlopen(self._request("/models"), timeout=20) as r:
                d = json.load(r)
        except urllib.error.HTTPError as e:
            raise LLMError(f"HTTP {e.code}: {e.read()[:800].decode(errors='replace')}") from e
        except OSError as e:
            raise LLMError(f"{self.provider.base_url}: {e}") from e
        # A standalone llama-server lists capabilities in an Ollama-style "models" array.
        multimodal = {m.get("model") or m.get("name"): any(c in ("multimodal", "vision") for c in m["capabilities"])
                      for m in d.get("models", []) if isinstance(m.get("capabilities"), list)}
        out = []
        for m in d.get("data", []):
            mid = str(m.get("id", "")).removeprefix("models/")  # Gemini prefixes ids
            mods = (m.get("architecture") or {}).get("input_modalities") or m.get("input_modalities")
            out.append(ModelInfo(mid, ("image" in mods) if isinstance(mods, list) else multimodal.get(mid)))
        return sorted(out, key=lambda m: m.id)

    def accepts_images(self) -> bool:
        if self.provider.vision == "images":
            return True
        if self.provider.vision == "text":
            return False
        try:
            for m in self.list_models():
                if m.id == self.provider.model and m.accepts_images is not None:
                    return m.accepts_images
        except LLMError:
            pass
        return any(h in self.provider.model.lower() for h in VISION_NAME_HINTS)

    def complete(self, messages: list[dict], on_delta: Callable[[str, str], None] | None = None) -> str:
        """Streams the answer; on_delta(content, reasoning) gets each chunk. Returns the answer, thinking removed."""
        body = {"model": self.provider.model, "messages": messages, "stream": True, **(self.provider.extra or {})}
        try:
            resp = urllib.request.urlopen(self._request("/chat/completions", body), timeout=self.timeout)
        except urllib.error.HTTPError as e:
            raise LLMError(f"HTTP {e.code}: {e.read()[:4000].decode(errors='replace')}") from e
        except OSError as e:
            raise LLMError(f"{self.provider.base_url}: {e}") from e
        out, reasoning = [], 0
        with resp:
            for raw in resp:
                line = raw.decode("utf-8", errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    obj = json.loads(payload)
                except ValueError:
                    continue
                if "error" in obj:
                    raise LLMError(str(obj["error"]))
                choices = obj.get("choices") or [{}]
                delta = choices[0].get("delta") or {}
                c = delta.get("content") or ""
                rc = delta.get("reasoning_content") or delta.get("reasoning") or ""
                out.append(c)
                reasoning += len(rc)
                if on_delta and (c or rc):
                    on_delta(c, rc)
        answer = strip_thinking("".join(out))
        if not answer:
            raise LLMError(f"the model returned no answer (only {reasoning} characters of reasoning); "
                           "try again or use another model")
        return answer


def strip_thinking(s: str) -> str:
    s = re.sub(r"(?s)<think>.*?</think>", "", s)
    if "</think>" in s:  # the opening tag was sent by the chat template
        s = s.split("</think>", 1)[1]
    return s.strip()
