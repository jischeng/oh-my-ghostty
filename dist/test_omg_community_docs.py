"""Offline community-document/entry-point contracts; no GitHub publication."""

from pathlib import Path
import re
import unittest
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
PUBLIC_DOCS = [
    "README.md", "README.zh-CN.md", "CONTRIBUTING.md",
    "docs/REPORTING.md", "docs/CONTRIBUTING.md",
    ".agents/skills/omg-issue-report/SKILL.md",
    ".github/pull_request_template.md",
]


class CommunityDocsTests(unittest.TestCase):
    def test_public_guides_exist_and_both_readmes_link_them(self):
        for path in PUBLIC_DOCS:
            self.assertTrue((ROOT / path).is_file(), path)
        for name in ["README.md", "README.zh-CN.md"]:
            text = (ROOT / name).read_text()
            for link in ["docs/REPORTING.md", "docs/CONTRIBUTING.md", "docs/RELEASING.md", "LICENSE"]:
                self.assertIn(link, text, name)
        self.assertIn("README.zh-CN.md", (ROOT / "README.md").read_text())
        self.assertIn("README.md", (ROOT / "README.zh-CN.md").read_text())

    def test_relative_markdown_and_html_links_resolve(self):
        for name in PUBLIC_DOCS:
            document = ROOT / name
            text = document.read_text()
            targets = re.findall(r"\[[^]]*\]\(([^)]+)\)", text)
            targets += re.findall(r'(?:href|src)="([^"]+)"', text)
            for raw in targets:
                target = raw.split(maxsplit=1)[0].strip("<>")
                if target.startswith(("https://", "http://", "mailto:", "#")):
                    continue
                target = unquote(target.split("#", 1)[0])
                self.assertTrue((document.parent / target).resolve().exists(), f"{name}: {target}")

    def test_readme_signing_and_product_status_are_not_stale(self):
        english = " ".join((ROOT / "README.md").read_text().lower().replace("**", "").split())
        for feature in ["quick input", "git inspector", "sent history"]:
            self.assertIn(feature, english)
        self.assertIn("self-signed", english)
        self.assertIn("not notarized", english)
        self.assertNotIn("ad-hoc signed", english)
        self.assertIn("not available yet", english)
        self.assertIn("pre-1.0", english)

    def test_all_inherited_vouch_jobs_are_upstream_only(self):
        workflows = sorted((ROOT / ".github/workflows").glob("vouch-*.yml"))
        self.assertGreaterEqual(len(workflows), 5)
        for path in workflows:
            text = path.read_text()
            jobs_section = text.split("jobs:\n", 1)[1]
            jobs = re.findall(r"(?ms)^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)", jobs_section)
            self.assertTrue(jobs, path.name)
            for job, body in jobs:
                conditions = re.findall(r"(?m)^    if: (.+)$", body)
                self.assertEqual(conditions, ["${{ github.repository == 'ghostty-org/ghostty' }}"],
                                 f"{path.name}: {job}")

    def test_report_helper_references_policy_and_requires_explicit_invocation(self):
        skill = (ROOT / ".agents/skills/omg-issue-report/SKILL.md").read_text()
        report = (ROOT / "docs/REPORTING.md").read_text()
        agents = (ROOT / "AGENTS.md").read_text()
        self.assertIn("disable-model-invocation: true", skill)
        self.assertIn("../../../docs/REPORTING.md", skill)
        self.assertNotIn("优先级高于", skill)
        self.assertIn("无需二次确认", skill)
        self.assertIn("no second confirmation", report)
        self.assertIn("/skill:omg-issue-report", report)
        self.assertIn("docs/REPORTING.md", agents)
        self.assertIn("gh issue create --repo jischeng/oh-my-ghostty", skill)
        self.assertIn("完整日志路径只私下返回给用户", skill)

    def test_github_templates_point_to_omg_guides(self):
        folder = ROOT / ".github/ISSUE_TEMPLATE"
        config = (folder / "config.yml").read_text()
        self.assertIn("blank_issues_enabled: true", config)
        self.assertIn("jischeng/oh-my-ghostty/blob/main/docs/REPORTING.md", config)
        for name in ["bug_report.yml", "feature_request.yml"]:
            text = (folder / name).read_text()
            self.assertIn("id: privacy", text)
            self.assertIn("id: ai_assistance", text)
            self.assertIn("jischeng/oh-my-ghostty/blob/main/docs/REPORTING.md", text)
        self.assertIn("docs/CONTRIBUTING.md", (ROOT / ".github/pull_request_template.md").read_text())


if __name__ == "__main__":
    unittest.main()
