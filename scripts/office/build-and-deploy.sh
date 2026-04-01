#!/bin/bash
# dcgm-exporter 사내 폐쇄망 빌드 & 배포 스크립트
# 사용법: ./scripts/office/build-and-deploy.sh [build|push|deploy|all]
set -euo pipefail

##############################################################################
# 설정 - 환경에 맞게 수정
##############################################################################
REGISTRY="${REGISTRY:-<사내-레지스트리>}"          # 예: harbor.example.com/gpu
IMAGE_NAME="dcgm-exporter"
IMAGE_TAG="${IMAGE_TAG:-4.5.2-4.8.1-ubuntu22.04-dra-v1beta2}"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

NAMESPACE="${NAMESPACE:-monitoring}"
RELEASE_NAME="${RELEASE_NAME:-dcgm-exporter}"

# 사내 프록시
PROXY="http://12.26.204.100:8080"

# SSL 인증서 (pip/requests용)
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

##############################################################################
# 함수
##############################################################################

build_image() {
    echo "=== 이미지 빌드 시작: ${FULL_IMAGE} ==="
    cd "${PROJECT_ROOT}"

    # samsungsemi-prx.crt 존재 확인
    if [ ! -f "samsungsemi-prx.crt" ]; then
        echo "ERROR: samsungsemi-prx.crt 파일이 프로젝트 루트에 없습니다."
        echo "  cp /usr/local/share/ca-certificates/samsungsemi-prx.crt ."
        exit 1
    fi

    docker build \
        --build-arg GOLANG_VERSION=1.24.13 \
        --build-arg DCGM_VERSION=4.5.2 \
        --build-arg VERSION=4.8.1 \
        --build-arg BASEIMAGE=nvcr.io/nvidia/cuda:13.1.1-base-ubuntu22.04 \
        --target runtime-ubuntu \
        --tag "${FULL_IMAGE}" \
        --file docker/Dockerfile \
        .

    echo "=== 빌드 완료: ${FULL_IMAGE} ==="
    docker images "${FULL_IMAGE}"
}

push_image() {
    echo "=== 이미지 Push: ${FULL_IMAGE} ==="
    docker push "${FULL_IMAGE}"
    echo "=== Push 완료 ==="
}

deploy_helm() {
    echo "=== Helm 배포: ${RELEASE_NAME} -> ${NAMESPACE} ==="
    cd "${PROJECT_ROOT}"

    helm upgrade --install "${RELEASE_NAME}" ./deployment \
        --namespace "${NAMESPACE}" \
        --create-namespace \
        --set image.repository="${REGISTRY}/${IMAGE_NAME}" \
        --set image.tag="${IMAGE_TAG}" \
        --set serviceMonitor.enabled=true

    echo "=== 배포 완료. 상태 확인 ==="
    kubectl -n "${NAMESPACE}" rollout status daemonset/"${RELEASE_NAME}" --timeout=120s || true
    kubectl -n "${NAMESPACE}" get ds "${RELEASE_NAME}"
}

verify() {
    echo "=== 배포 검증 ==="
    echo "--- DaemonSet 상태 ---"
    kubectl -n "${NAMESPACE}" get ds "${RELEASE_NAME}"
    echo ""
    echo "--- Pod 상태 ---"
    kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=dcgm-exporter
    echo ""
    echo "--- 최근 로그 (v1beta1 에러 확인) ---"
    kubectl -n "${NAMESPACE}" logs -l app.kubernetes.io/name=dcgm-exporter --tail=20 2>/dev/null || echo "(로그 조회 실패)"
}

usage() {
    echo "사용법: $0 [build|push|deploy|verify|all]"
    echo ""
    echo "  build   - Docker 이미지 빌드"
    echo "  push    - 사내 레지스트리에 Push"
    echo "  deploy  - Helm으로 K8s 배포"
    echo "  verify  - 배포 상태 확인"
    echo "  all     - build + push + deploy + verify"
    echo ""
    echo "환경변수:"
    echo "  REGISTRY   - 레지스트리 주소 (기본: <사내-레지스트리>)"
    echo "  IMAGE_TAG  - 이미지 태그 (기본: 4.5.2-4.8.1-ubuntu22.04-dra-v1beta2)"
    echo "  NAMESPACE  - K8s 네임스페이스 (기본: monitoring)"
}

##############################################################################
# 메인
##############################################################################
ACTION="${1:-}"

case "${ACTION}" in
    build)   build_image ;;
    push)    push_image ;;
    deploy)  deploy_helm ;;
    verify)  verify ;;
    all)     build_image && push_image && deploy_helm && verify ;;
    *)       usage; exit 1 ;;
esac
