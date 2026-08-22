from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


class SourcePreviewContractsTest(unittest.TestCase):
    def test_publish_pointer_rechecks_source_pr_before_and_after_pointer_writes(self) -> None:
        script = read("scripts/source-preview/publish-railway-preview-pointer.sh")

        self.assertIn("recheck_source_pr()", script)
        self.assertIn("SOURCE_RECHECK_TOKEN", script)
        self.assertIn('gh api "repos/${SOURCE_REPOSITORY}/pulls/${SOURCE_PR_NUMBER}"', script)
        self.assertIn('${current_state}" != "open"', script)
        self.assertIn('${current_draft}" = "true"', script)
        self.assertIn('${current_sha}" != "${SOURCE_SHA}"', script)

        before_call = script.index('recheck_source_pr "before-writing-pointer"')
        source_env_write = script.index('> "${target}/source.env"')
        source_json_write = script.index('> "${target}/.source.json"')
        after_call = script.index('recheck_source_pr "after-writing-pointer"')
        git_add = script.index('git add "${target}/source.env" "${target}/.source.json"')

        self.assertLess(before_call, source_env_write)
        self.assertLess(source_env_write, source_json_write)
        self.assertLess(source_json_write, after_call)
        self.assertLess(after_call, git_add)

    def test_close_pointer_uses_bounded_retry_lookup_before_absent_exit(self) -> None:
        script = read("scripts/source-preview/close-railway-preview-pointer.sh")

        self.assertIn('lookup_open_preview_pr()', script)
        self.assertIn('CLOSE_POINTER_LOOKUP_ATTEMPTS:-6', script)
        self.assertIn('CLOSE_POINTER_LOOKUP_SLEEP_SECONDS:-10', script)
        self.assertIn('for attempt in $(seq 1 "${lookup_attempts}")', script)
        self.assertIn('retrying in ${lookup_sleep_seconds}s', script)
        self.assertIn('after ${lookup_attempts} lookup attempts', script)

        retry_loop = script.index('for attempt in $(seq 1 "${lookup_attempts}")')
        absent_exit = script.index('No open deployment preview PR found for ${preview_branch} after ${lookup_attempts} lookup attempts.')
        close_patch = script.index('jq -n \'{state: "closed"}\'')

        self.assertLess(retry_loop, absent_exit)
        self.assertLess(absent_exit, close_patch)

    def test_source_preview_workflows_keep_pinned_checkout_and_explicit_secrets(self) -> None:
        open_update = read(".github/workflows/source-preview-pointer-open-update.yml")
        close = read(".github/workflows/source-preview-pointer-close.yml")

        for workflow in (open_update, close):
            self.assertIn("actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09", workflow)
            self.assertNotIn("secrets: inherit", workflow)
            self.assertIn("OPENBAO_ADDR:", workflow)
            self.assertIn("OPENBAO_AUTH_PATH:", workflow)
            self.assertIn("OPENBAO_AUDIENCE:", workflow)
            self.assertIn("OPENBAO_ROLE:", workflow)
            self.assertIn("OPENBAO_SECRET_PATH:", workflow)

        self.assertIn("SOURCE_RECHECK_TOKEN: ${{ github.token }}", open_update)

    def test_runtime_auth_placeholder_checker_covers_known_redactions(self) -> None:
        checker = read("scripts/check-auth-placeholders.py")

        self.assertIn('"ACTI" + "..." + "KEN"', checker)
        self.assertIn('"SOUR" + "..." + "EN"', checker)
        self.assertIn('"DEPL" + "..." + "git"', checker)
        self.assertIn('"x-access-token:***"', checker)
        self.assertIn('"Bearer ***"', checker)
        self.assertIn('"AUTHORIZATION: basic ***"', checker)


if __name__ == "__main__":
    unittest.main()
