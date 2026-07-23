import unittest
from unittest.mock import patch

from github_credential_validator import (
    validate_credential,
    validate_credential_metadata,
    validate_repository,
    validate_token_type,
)


class GitHubCredentialValidatorTests(unittest.TestCase):
    def test_accepts_read_only_repository_permissions(self) -> None:
        validate_credential_metadata(
            {
                "permissions": {
                    "admin": False,
                    "maintain": False,
                    "push": False,
                    "triage": False,
                    "pull": True,
                }
            },
        )

    def test_rejects_write_permissions(self) -> None:
        with self.assertRaisesRegex(ValueError, "write-capable"):
            validate_credential_metadata(
                {"permissions": {"pull": True, "push": True}},
            )

    def test_accepts_fine_grained_and_installation_token_types(self) -> None:
        validate_token_type("github_pat_example")
        validate_token_type("ghs_example")

    def test_rejects_classic_and_oauth_token_types(self) -> None:
        for token in ("ghp_example", "gho_example", "ghu_example"):
            with self.subTest(token=token):
                with self.assertRaisesRegex(ValueError, "Classic PAT and OAuth"):
                    validate_token_type(token)

    @patch("github_credential_validator.request_github_json")
    def test_checks_all_required_read_endpoints(self, request_json) -> None:
        request_json.return_value = {
            "permissions": {
                "admin": False,
                "maintain": False,
                "push": False,
                "triage": False,
                "pull": True,
            }
        }

        validate_credential("owner/repository", "github_pat_example")

        self.assertEqual(request_json.call_count, 5)

    def test_requires_owner_and_repository(self) -> None:
        with self.assertRaisesRegex(ValueError, "owner/repository"):
            validate_repository("missing-owner")


if __name__ == "__main__":
    unittest.main()
