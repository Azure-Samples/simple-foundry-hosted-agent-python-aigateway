import unittest
from unittest.mock import patch

from github_credential_validator import (
    REPOSITORY_PATTERN,
    evaluate_credential,
)


class GitHubCredentialValidatorTests(unittest.TestCase):
    def test_broad_token_warns_and_points_to_fix_doc(self) -> None:
        warnings = evaluate_credential("owner/repository", "gho_example")

        self.assertEqual(len(warnings), 1)
        self.assertIn(
            "IMPLEMENTATION_NOTES.md#tighten-the-github-credential-to-least-privilege",
            warnings[0],
        )

    @patch("github_credential_validator.request_github_json")
    def test_read_only_fine_grained_token_has_no_warnings(self, request_json) -> None:
        request_json.return_value = {
            "permissions": {
                "admin": False,
                "maintain": False,
                "push": False,
                "triage": False,
                "pull": True,
            }
        }

        warnings = evaluate_credential("owner/repository", "github_pat_example")

        self.assertEqual(warnings, [])

    @patch("github_credential_validator.request_github_json")
    def test_write_permissions_warn(self, request_json) -> None:
        request_json.return_value = {"permissions": {"pull": True, "push": True}}

        warnings = evaluate_credential("owner/repository", "github_pat_example")

        self.assertTrue(any("write-capable" in warning for warning in warnings))

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

        evaluate_credential("owner/repository", "github_pat_example")

        self.assertEqual(request_json.call_count, 5)

    def test_repository_pattern_requires_owner_and_repository(self) -> None:
        self.assertIsNone(REPOSITORY_PATTERN.fullmatch("missing-owner"))
        self.assertIsNotNone(REPOSITORY_PATTERN.fullmatch("owner/repository"))


if __name__ == "__main__":
    unittest.main()
