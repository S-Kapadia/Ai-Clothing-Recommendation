import importlib

import pytest

PACKAGES = [
    "pipeline.crawl",
    "pipeline.classify",
    "pipeline.charts",
    "pipeline.normalize",
    "pipeline.variants",
    "models.body",
    "models.fit",
    "models.embed",
    "models.style",
    "serving.api",
    "serving.demo",
    "eval.run_all",
]


@pytest.mark.parametrize("package", PACKAGES)
def test_package_imports(package: str) -> None:
    importlib.import_module(package)
