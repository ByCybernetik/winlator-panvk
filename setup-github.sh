#!/bin/bash
# Создать репозиторий github.com/Cybernetik/winlator-panvk и запушить.
set -euo pipefail

cd "$(dirname "$0")"
GITHUB_USER="${GITHUB_USER:-ByCybernetik}"
GITHUB_REPO="${GITHUB_REPO:-winlator-panvk}"

GH="$(command -v gh || true)"
if [[ -z "$GH" ]]; then
    echo "Установи GitHub CLI: sudo pacman -S github-cli"
    echo "Затем: gh auth login"
    exit 1
fi

if ! gh auth status &>/dev/null; then
    echo "Войди в GitHub:"
    gh auth login
fi

if gh repo view "${GITHUB_USER}/${GITHUB_REPO}" &>/dev/null; then
    echo "Репозиторий уже существует, push ..."
    git remote remove origin 2>/dev/null || true
    git remote add origin "https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git"
    git push -u origin main
else
    echo "Создаю github.com/${GITHUB_USER}/${GITHUB_REPO} ..."
    gh repo create "${GITHUB_REPO}" --public --source=. --remote=origin --push \
        --description "Build PanVK tzst for Winlator Mali (GitHub Actions)"
fi

echo ""
echo "Готово: https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
echo "Actions → Build PanVK → Run workflow"
