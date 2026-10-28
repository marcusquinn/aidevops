"""Versioned process evidence; no ownership or deletion authority."""

from dataclasses import asdict, dataclass
from typing import Literal, Protocol
from uuid import UUID


class ObservationUnavailable(Exception):
    """A safe, non-sensitive reason that identity cannot be established."""


@dataclass(frozen=True)
class ProcessIdentity:
    schema: int
    installation_id: str
    platform: str
    boot_id: str
    scope: str
    pid: int
    generation: str
    uid: int

    @classmethod
    def from_dict(cls, value: object) -> "ProcessIdentity":
        if not isinstance(value, dict) or set(value) != set(cls.__dataclass_fields__):
            raise ValueError("invalid-identity-fields")
        identity = cls(**value)
        identity.validate()
        return identity

    def validate(self) -> None:
        if type(self.schema) is not int or self.schema != 1:  # pylint: disable=unidiomatic-typecheck  # Reject bool
            raise ValueError("unsupported-identity-schema")
        for value in (self.installation_id, self.boot_id):
            if not isinstance(value, str) or str(UUID(value)) != value:
                raise ValueError("invalid-identity-uuid")
        if type(self.pid) is not int or not 0 < self.pid <= 2**31 - 1:  # pylint: disable=unidiomatic-typecheck  # Reject bool
            raise ValueError("invalid-pid")
        if type(self.uid) is not int or not 0 <= self.uid < 2**32:  # pylint: disable=unidiomatic-typecheck  # Reject bool
            raise ValueError("invalid-uid")
        for value in (self.platform, self.scope, self.generation):
            if not isinstance(value, str) or not value or len(value) > 256:
                raise ValueError("invalid-identity-token")

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass(frozen=True)
class ProcessObservation:
    status: Literal["alive", "ended", "unknown"]
    reason: str

    def to_dict(self) -> dict:
        return asdict(self)


class ProcessAdapter(Protocol):
    def capture(self, pid: int) -> ProcessIdentity: ...

    def observe(self, identity: ProcessIdentity) -> ProcessObservation: ...
