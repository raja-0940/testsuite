"""LlmSim implementation for backend"""

from testsuite.backend import Backend
from testsuite.kubernetes import Selector
from testsuite.kubernetes.client import KubernetesClient
from testsuite.kubernetes.deployment import Deployment
from testsuite.kubernetes.service import Service, ServicePort
from testsuite.utils.constants import HTTP_API_PORT


# external_ip is an optional Exposable capability that this backend does not provide
class LlmSim(Backend):  # pylint: disable=abstract-method
    """LlmSim deployed in Kubernetes as Backend"""

    def __init__(self, cluster: KubernetesClient, name, model, label, image, replicas=1) -> None:
        super().__init__(cluster, name, label)
        self.model = model
        self.replicas = replicas
        self.image = image

    def commit(self):
        match_labels = {"app": self.label, "deployment": self.name}
        self.deployment = Deployment.create_instance(
            self.cluster,
            self.name,
            container_name="llm-sim",
            image=self.image,
            ports={"api": HTTP_API_PORT},
            selector=Selector(matchLabels=match_labels),
            labels={"app": self.label},
            # ppc64le-fix: llm-sim — the real HF model name makes llm-d-inference-sim v0.9 use the HF
            # tokenizer, which needs a render sidecar on localhost:8082 (not deployed) -> crash/500.
            # Use a non-HF --model (simulated tokenizer) and keep the requested name via
            # --served-model-name, so the API model id is unchanged. --mode echo: deterministic output.
            command_args=[
                "--model", "kuadrant-sim/llm",
                "--served-model-name", self.model,
                "--port", str(HTTP_API_PORT),
                "--mode", "echo",
            ],
        )
        self.deployment.commit()
        self.deployment.wait_for_ready()

        self.service = Service.create_instance(
            self.cluster,
            self.name,
            selector=match_labels,
            ports=[ServicePort(name="http", port=HTTP_API_PORT, targetPort="api")],
        )
        self.service.commit()
