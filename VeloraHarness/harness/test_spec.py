# -*- mode: python; mode: blacken -*-
import json
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional, Union

import pandas as pd
from projects.agents.swebench.harness.test_spec.test_spec import TestSpec
from swebench.harness.constants import (
    END_TEST_OUTPUT,
    FAIL_TO_PASS,
    MAP_REPO_VERSION_TO_SPECS,
    PASS_TO_PASS,
    START_TEST_OUTPUT,
    SWEbenchInstance,
)

from ..test.constants import DEFAULT_LOG_PARSER
from ..test.repomate_constants import REPOMATE_NAMESPACE
from ..util.evaluation import Testbed

logger = logging.getLogger()


def get_default_test_cmd_for_language(language: str) -> str:
    """Get the default test command for a given programming language in repomate.

    Args:
        language: Programming language code

    Returns:
        str: Default test command for the language
    """
    language_to_default_test_cmd = {
        "python": "pytest",
        "javascript": "npm test",
        "java": "mvn test",
        "c": "make check",
        "cpp": "make test",
        "go": "go test",
        "rust": "cargo test",
    }

    return language_to_default_test_cmd.get(
        language,
        "pytest",
    )


def get_test_cmd_for_repomate_instance(
    test_cmd_parser: Optional[str], test_cmd: Optional[str]
) -> str:
    """Get the appropriate test command for a repomate instance.

    Args:
        test_cmd_parser: parser command in the format language/test_framework (eg python/parse_log_unittest)
        test_cmd: Test command from environment

    Returns:
        str: Test command to use
    """
    if test_cmd is not None and test_cmd != "":
        return test_cmd

    if test_cmd_parser and "/" in test_cmd_parser:
        repo_language = test_cmd_parser.split("/")[0].lower()
    else:
        repo_language = "python"
    return get_default_test_cmd_for_language(repo_language)


@dataclass
class RepomateTestSpec(TestSpec):
    image_storage_uri: Optional[str] = None


class RepomateTestbed(Testbed):
    def get_instance_image_key(
        self, use_vmvm: bool = False, load_groundtruth: bool = False
    ) -> str:
        if not use_vmvm:
            logger.warning("Repomate images are required to use VMVM")
            key = self.test_spec.instance_image_key
            key = key.replace("sweb.eval.x86_64.", "")
            key = key.replace("_1776_", "__")
        else:
            instance_id = self.test_spec.instance_id
            image_storage_uri = getattr(self.test_spec, "image_storage_uri", None)
            if image_storage_uri:
                return image_storage_uri
            converted = get_repomate_instance_image_key(instance_id)
            key = f"{self.PROD_REGISTRY_NAMESPACE}/{self.test_spec.vmvm_dataset_name}/{converted}"
            # key = f"{self.test_spec.vmvm_dataset_name}/{converted}"
        return key

    def get_tar_file_path(self, images_dir: str | Path) -> Path:
        raise NotImplementedError("Repomate does not use tar files")

    @classmethod
    def get_workdir(cls):
        return "/app/repo"


run_instance = RepomateTestbed.run_instance


def get_repomate_instance_image_key(instance_id: str) -> str:
    return instance_id.rsplit("-", 1)[0] + ":" + instance_id.rsplit("-", 1)[1]


def make_eval_test_spec(instance: Union[SWEbenchInstance, dict[str, Any]]) -> TestSpec:
    if "repo" in instance:
        repo = instance["repo"]
    else:
        repo = instance["instance_id"].resplit("-", 1)[0].replace("__", "/")

    version = "repomate"
    # Our containers should not require any post-install to be performed, since they run
    # in an environment without network access.
    specs = MAP_REPO_VERSION_TO_SPECS[repo][version]

    test_patch = instance["test_patch"]
    base_commit = instance["base_commit"]
    repo_directory = "/app/repo"

    HEREDOC_DELIMITER = "EOF_114329324912"
    # Reset test files to the state they should be in before the patch.
    apply_test_patch_command = (
        f"git apply -v - <<'{HEREDOC_DELIMITER}'\n{test_patch}\n{HEREDOC_DELIMITER}"
    )
    test_command = instance["test_command"]
    # if "pytest" in test_command:
    #     test_command = test_command.replace("pytest", "pytest -rA ")
    logger.info(f"test_command: {test_command}")
    eval_commands = [
        f"cd {repo_directory}",
    ]
    if "eval_commands" in specs:
        eval_commands += specs["eval_commands"]
    eval_commands += [
        "source /saved/ENV || source /saved/*/ENV",
        f"cd {repo_directory}",
        f"git config --global --add safe.directory {repo_directory}",  # for nonroot user
        f"cd {repo_directory}",
        # This is just informational, so we have a record
        "git status",
        "git show",
        f"git -c core.fileMode=false diff {base_commit}",
    ]
    if "install" in specs:
        eval_commands.append(specs["install"])
    eval_commands += [
        apply_test_patch_command,
        f": '{START_TEST_OUTPUT}'",
        test_command,
        f": '{END_TEST_OUTPUT}'",
    ]

    eval_script_list = eval_commands
    logger.debug(f"eval_script_list: {eval_script_list}")

    def _from_json_or_obj(value: Any) -> Any:
        return json.loads(value) if isinstance(value, str) else value

    return RepomateTestSpec(
        instance_id=instance["instance_id"],
        repo=repo,
        env_script_list=[],
        repo_script_list=[],
        eval_script_list=eval_script_list,
        version=version,
        arch="x86_64",
        FAIL_TO_PASS=_from_json_or_obj(instance[FAIL_TO_PASS]),
        PASS_TO_PASS=_from_json_or_obj(instance[PASS_TO_PASS]),
        language="py",
        docker_specs={},
        namespace=REPOMATE_NAMESPACE,
        vmvm_dataset_name="repomate_image_activ_pytest",
        container_mem="4g",
        container_memswap="4g",
        image_storage_uri=instance.get("image_storage_uri"),
    )


def create_repomate_instance_specs(dataset: str):
    data = pd.read_parquet(dataset)
    from swebench.harness.constants import MAP_REPO_TO_EXT, MAP_REPO_VERSION_TO_SPECS
    from swebench.harness.log_parsers import MAP_REPO_TO_PARSER

    from ..test import repomate_log_parsers

    for _, instance in data.iterrows():
        spec_v = {"repomate": {"test_cmd": instance["test_command"]}}
        k = instance["repo"]
        if k not in MAP_REPO_VERSION_TO_SPECS:
            MAP_REPO_VERSION_TO_SPECS[k] = spec_v
            MAP_REPO_VERSION_TO_SPECS[k.lower()] = spec_v
        else:
            MAP_REPO_VERSION_TO_SPECS[k].update(spec_v)
            MAP_REPO_VERSION_TO_SPECS[k.lower()].update(spec_v)

        parser_information = instance["test_output_parser"]
        language, parser_name = parser_information.split("/")
        parser_v = getattr(repomate_log_parsers, parser_name, None)
        if k not in MAP_REPO_TO_PARSER:
            MAP_REPO_TO_PARSER[k] = parser_v
            MAP_REPO_TO_PARSER[k.lower()] = parser_v
        else:
            # If it's already a dict, just add the new parser
            if isinstance(MAP_REPO_TO_PARSER[k], dict):
                MAP_REPO_TO_PARSER[k]["repomate"] = parser_v
            else:
                # Convert to dict format and preserve existing parser
                MAP_REPO_TO_PARSER[k] = {
                    DEFAULT_LOG_PARSER: MAP_REPO_TO_PARSER[k],
                    "repomate": parser_v,
                }

            # Same logic for lowercase
            if isinstance(MAP_REPO_TO_PARSER[k.lower()], dict):
                MAP_REPO_TO_PARSER[k.lower()]["repomate"] = parser_v
            else:
                MAP_REPO_TO_PARSER[k.lower()] = {
                    DEFAULT_LOG_PARSER: MAP_REPO_TO_PARSER[k.lower()],
                    "repomate": parser_v,
                }

        if k not in MAP_REPO_TO_EXT:
            MAP_REPO_TO_EXT[k] = "py"
            MAP_REPO_TO_EXT[k.lower()] = "py"

    logging.info(f"Added repo to spec, parser and ext for repomate images")
