resource "kubernetes_namespace" "observability" {
  metadata {
    name = "observability"
  }
  depends_on = [ module.eks ]
}

resource "helm_release" "promtail" {
  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  namespace  = "observability"

  values = [
    "${file("${path.module}/../workload/promtail/values.yaml")}"
  ]

  depends_on = [ kubernetes_namespace.observability,module.eks ]
}

resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  namespace  = "observability"

  values = [
    "${file("${path.module}/../workload/loki/values.yaml")}"
  ]

  depends_on = [ kubernetes_namespace.observability,module.eks ]
}

resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  namespace  = "observability"

  depends_on = [ kubernetes_namespace.observability,module.eks ]
}

# resource "kubernetes_manifest" "grafana_pvc" {
#   manifest = yamldecode(file("${path.module}/../workload/grafana/pvc.yaml"))

#   depends_on = [ kubernetes_namespace.observability, module.eks ]
# }

# resource "kubernetes_manifest" "grafana_deployment" {
#   manifest = yamldecode(file("${path.module}/../workload/grafana/deployment.yaml"))

#   depends_on = [ kubernetes_manifest.grafana_pvc, module.eks ]
# }

# resource "kubernetes_manifest" "grafana_service" {
#   manifest = yamldecode(file("${path.module}/../workload/grafana/service.yaml"))

#   depends_on = [ kubernetes_manifest.grafana_deployment, module.eks ]
# }

# resource "kubernetes_manifest" "grafana_ingress" {
#   manifest = yamldecode(file("${path.module}/../workload/grafana/ingress.yaml"))

#   depends_on = [ 
#     kubernetes_manifest.grafana_service,
#     helm_release.lb, 
#     module.eks
#    ]
# }