# opencode-plugin-auto-update

`opencode-plugin-auto-update`는 Windows 환경에서 OpenCode가 관리하는 npm 플러그인을 매일 최초 OpenCode 실행 시점에 자동 점검하고, 필요 시 캐시 갱신·리네임 마이그레이션·OpenCode 자동 재시작까지 수행하는 PowerShell 기반 도구입니다.

특히 `@latest`가 항상 즉시 최신 버전으로 반영되지 않을 수 있는 OpenCode 플러그인 캐시 특성과, `oh-my-opencode -> oh-my-openagent` 같은 rename/dual-publish 상황을 운영 관점에서 안전하게 다루는 데 초점을 둡니다.

## 구성

- `scripts/OpenCodePluginAutoUpdate.psm1` — 핵심 모듈
- `scripts/Update-OpenCodePlugins.ps1` — 갱신 엔진 단독 실행
- `scripts/Launch-OpenCodeWithAutoUpdate.ps1` — 최초 실행 가드 + OpenCode 실행 래퍼
- `scripts/Install-OpenCodePluginAutoUpdate.ps1` — Desktop/Start Menu shortcut 설치
- `scripts/Uninstall-OpenCodePluginAutoUpdate.ps1` — shortcut 제거
- `config/known-plugin-renames.json` — 고신뢰 리네임 규칙
- `tests/OpenCodePluginAutoUpdate.Tests.ps1` — Pester 회귀 테스트
- `.github/workflows/ci.yml` — GitHub Actions 기반 lint/test CI

## 동작 방식

1. `%USERPROFILE%\.config\opencode\opencode.json`의 `plugin` 배열을 읽습니다.
2. `%USERPROFILE%\.cache\opencode\package.json` 및 `node_modules/<pkg>/package.json`에서 실제 resolved 버전을 읽습니다.
3. npm registry의 `dist-tags.latest`, 최신 metadata, deprecated 메시지를 조회합니다.
4. 필요한 경우 `known-plugin-renames.json`과 deprecated 메시지를 사용해 rename migration 대상을 계산합니다.
5. 변경이 있으면 `%USERPROFILE%\.cache\opencode`에서 `bun add --force --exact --cwd <cache> <pkg>@<spec>`를 수행합니다.
6. 갱신이 있었으면 OpenCode 프로세스를 재시작합니다.
7. 하루에 한 번만 실행되도록 `%USERPROFILE%\.config\opencode-plugin-auto-update\state\daily-state.json`에 상태를 기록합니다.

## 로그/상태 위치

- 상태: `%USERPROFILE%\.config\opencode-plugin-auto-update\state\daily-state.json`
- 잠금: `%USERPROFILE%\.config\opencode-plugin-auto-update\state\run.lock`
- 백업: `%USERPROFILE%\.config\opencode-plugin-auto-update\backups\`
- 저널: `%USERPROFILE%\.config\opencode-plugin-auto-update\journal\`
- 로그: `%USERPROFILE%\.config\opencode-plugin-auto-update\logs\`

## 사용법

### 1) 바로 갱신만 실행

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Update-OpenCodePlugins.ps1 -Force
```

의사결정만 확인하려면:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Update-OpenCodePlugins.ps1 -DryRun -Force
```

### 2) OpenCode 실행 래퍼 사용

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Launch-OpenCodeWithAutoUpdate.ps1
```

### 3) 바로가기 설치

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-OpenCodePluginAutoUpdate.ps1
```

## 테스트

```powershell
pwsh -NoProfile -Command "Invoke-Pester .\tests\OpenCodePluginAutoUpdate.Tests.ps1"
```

## 보안 및 운영 주의사항

- 이 도구는 `%USERPROFILE%\.config\opencode\opencode.json`을 수정할 수 있으므로, 변경 전 자동 백업을 생성합니다.
- 업데이트가 실제로 발생하면 OpenCode 프로세스를 종료 후 재시작할 수 있습니다.
- 로그/저널에는 로컬 경로와 패키지 메타데이터가 포함될 수 있으므로 외부 공유 전 검토가 필요합니다.
- 문서 예시에 포함된 `-ExecutionPolicy Bypass`는 설치 편의용 예시입니다. 조직 정책이 있으면 그 정책에 맞는 실행 방식을 사용하세요.

## 알려진 제한사항

- 리네임 자동 대응은 `deprecated` 메타데이터와 `config/known-plugin-renames.json`에 의존합니다.
- OpenCode 프로세스 감지는 `Win32_Process.CommandLine` 기반이므로 설치 형태에 따라 추가 보정이 필요할 수 있습니다.
- OpenCode가 직접 실행되는 기존 바로가기를 계속 쓰면 “최초 실행 시 자동 점검” 보장은 약해집니다. 이 경우 `Launch-OpenCodeWithAutoUpdate.ps1` 또는 설치 스크립트가 만든 shortcut을 사용해야 합니다.
