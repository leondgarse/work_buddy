"""Providers, people and limits. One JSON file, private to the user (it may hold an API key)."""
from __future__ import annotations

import json
import os
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from urllib.parse import urlparse

LOCAL_SAMPLING = {"temperature": 0.3}  # local models wander at ~1.0; 0.3 scored higher and ran ~3x faster
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1"}
MAC_APP_SETTINGS = Path("~/Library/Application Support/ReqBuddy/settings.json").expanduser()


@dataclass
class Provider:
    name: str
    base_url: str                     # OpenAI-compatible, ending before /chat/completions
    model: str
    api_key_env: str = ""             # env var holding the key
    api_key: str = ""                 # or the key itself (the config file is chmod 600)
    vision: str = "auto"              # auto | images | text
    extra: dict = field(default_factory=dict)  # merged into the request body

    @property
    def is_local(self) -> bool:
        return (urlparse(self.base_url).hostname or "").lower() in LOCAL_HOSTS

    def key(self) -> str | None:
        if self.api_key:
            return self.api_key
        if self.api_key_env:
            return os.environ.get(self.api_key_env) or _login_shell_env(self.api_key_env)
        return None


@dataclass
class Person:
    name: str
    role: str
    aliases: str = ""                 # emails, handles, other spellings
    me: bool = False


@dataclass
class Config:
    providers: list[Provider]
    default_provider: str
    people: list[Person]
    system_prompt: str = ""           # empty = the built-in prompt
    max_images: int = 16
    image_side: int = 1600            # long side (px) of images sent to the model
    cases_url: str = "http://127.0.0.1:8110"
    transcriber: str = ""             # "provider[|model]": a vision model that transcribes pictures for a text-only model

    def provider(self, name: str | None = None) -> Provider:
        """By name prefix (case-insensitive); None = the default."""
        want = (name or self.default_provider).lower()
        for p in self.providers:
            if p.name.lower() == want:
                return p
        for p in self.providers:
            if p.name.lower().startswith(want):
                return p
        raise KeyError(f"unknown provider {name!r}; have: {', '.join(p.name for p in self.providers)}")

    def to_json(self) -> str:
        return json.dumps(asdict(self), ensure_ascii=False, indent=2)

    @classmethod
    def from_dict(cls, d: dict) -> Config:
        base = defaults()
        return cls(
            providers=[Provider(**p) for p in d.get("providers", [])] or base.providers,
            default_provider=d.get("default_provider", base.default_provider),
            people=[Person(**p) for p in d.get("people", [])] or base.people,
            system_prompt=d.get("system_prompt", ""),
            max_images=d.get("max_images", base.max_images),
            image_side=d.get("image_side", base.image_side),
            cases_url=d.get("cases_url", base.cases_url),
            transcriber=d.get("transcriber", ""),
        )


def defaults() -> Config:
    return Config(
        providers=[
            Provider("Gemini", "https://generativelanguage.googleapis.com/v1beta/openai", "gemini-3.8-flash",
                     api_key_env="GEMINI_API_KEY", vision="images"),
            Provider("DeepSeek", "https://api.deepseek.com/v1", "deepseek-flash", api_key_env="DEEPSEEK_API_KEY"),
            # A local llama.cpp server; another one (router) may serve other models. Don't ask a router for a
            # model another server already holds: two copies may not fit on the GPUs.
            Provider("Local 35B :18010", "http://localhost:18010/v1", "Qwen3.6-35B-A3B-Q8_0",
                     api_key_env="QWEN36_API_KEY", extra=dict(LOCAL_SAMPLING)),
            Provider("Local router :8080", "http://localhost:8080/v1", "DavidAU/Qwen3.6-27B-Fable-Fus-711",
                     extra=dict(LOCAL_SAMPLING)),
        ],
        default_provider="Gemini",
        people=[
            Person("Jane Doe", "CTO of our company; her decisions are final", "jane@example.com"),
            Person("Your Name", "Me - the developer who will implement this", "you@example.com", me=True),
        ],
    )


def config_path() -> Path:
    if os.environ.get("REQBUDDY_CONFIG"):
        return Path(os.environ["REQBUDDY_CONFIG"]).expanduser()
    base = Path(os.environ.get("XDG_CONFIG_HOME") or "~/.config").expanduser()
    return base / "reqbuddy" / "config.json"


def load() -> Config:
    path = config_path()
    if path.exists():
        return Config.from_dict(json.loads(path.read_text()))
    cfg = import_mac_app() if MAC_APP_SETTINGS.exists() else None
    if cfg:
        save(cfg)
        print(f"reqbuddy: imported the macOS app's settings into {path}", file=sys.stderr)
        return cfg
    return defaults()


def save(cfg: Config) -> Path:
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(cfg.to_json() + "\n")
    path.chmod(0o600)
    return path


def import_mac_app(settings: Path = MAC_APP_SETTINGS) -> Config | None:
    """Carry over the retired macOS app's providers, people and limits (keys from its Keychain entries)."""
    try:
        d = json.loads(settings.read_text())
    except (OSError, ValueError):
        return None
    providers = []
    for p in d.get("providers", []):
        try:
            extra = json.loads(p.get("extraBody") or "{}")
        except ValueError:
            extra = {}
        vision = {"images": "images", "ocr": "text"}.get(p.get("vision", "auto"), "auto")
        providers.append(Provider(p["name"], p["baseURL"], p["model"], p.get("apiKeyEnv", ""),
                                  _keychain(p.get("id", "")), vision, extra))
    people = [Person(x["name"], x.get("role", ""), x.get("aliases", ""), bool(x.get("isMe")))
              for x in d.get("people", []) if x.get("name")]
    chosen = next((p["name"] for p in d.get("providers", []) if p.get("id") == d.get("selectedProviderID")), None)
    base = defaults()
    return Config(providers or base.providers, chosen or (providers[0].name if providers else base.default_provider),
                  people or base.people, d.get("systemPrompt", ""), d.get("maxImages", 16),
                  cases_url=d.get("casesBaseURL", base.cases_url))


def _keychain(account: str) -> str:
    if not account or sys.platform != "darwin":
        return ""
    r = subprocess.run(["security", "find-generic-password", "-s", "ReqBuddy", "-a", account, "-w"],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


_shell_cache: dict[str, str | None] = {}


def _login_shell_env(name: str) -> str | None:
    """A key exported in ~/.zshrc is missing when launched outside a shell (e.g. a service)."""
    if name in _shell_cache or not name.replace("_", "").isalnum():
        return _shell_cache.get(name)
    shell = os.environ.get("SHELL", "/bin/sh")
    try:
        r = subprocess.run([shell, "-ilc", f'printf %s "${name}"'], capture_output=True, text=True,
                           timeout=10, stdin=subprocess.DEVNULL)
        val = r.stdout.strip().splitlines()[-1].strip() if r.stdout.strip() else None
    except (OSError, subprocess.TimeoutExpired):
        val = None
    _shell_cache[name] = val or None
    return _shell_cache[name]
