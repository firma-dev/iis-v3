#!/bin/sh
# Запись в ящик с настоящим временем.
#   sh запись.sh <кому> <от> "<тема>" < текст
# Корень лаборатории — LAB_ROOT; если не задан, берётся из места скрипта
# (<корень>/связь/скрипты/запись.sh). Часовой пояс — LAB_TZ (по умолчанию UTC).
# Время берётся из часов машины, а не пишется на глаз.
# Шапка: «## от X, ДД.ММ.ГГГГ ЧЧ:ММ — тема». Новое сверху (после трёх строк шапки ящика).
# Замок на «прочитать–записать–закоммитить»: mkdir-замок, повтор до ~30 с,
# снятие в trap. Если корень не git-репозиторий или не настроена личность git,
# запись остаётся в файле без коммита (с сообщением).
# Имена переменных латиницей: sh не принимает кириллицу в именах, а `sh -n`
# этого не ловит.
set -eu
[ "$#" -ge 3 ] || { echo "запись.sh: нужно <кому> <от> \"<тема>\"" >&2; exit 64; }
TO="$1"; FROM="$2"; TOPIC="$3"
case "$TO" in */*|..*|"") echo "запись.sh: недопустимое имя ящика" >&2; exit 64;; esac
if [ -n "${LAB_ROOT:-}" ]; then
  ROOT="$LAB_ROOT"
else
  ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fi
BOX="$ROOT/связь/ящики/$TO.md"
REL="связь/ящики/$TO.md"
LOCK="$ROOT/связь/.замок-$TO"
[ -f "$BOX" ] || { echo "нет ящика $TO ($BOX)" >&2; exit 1; }
BODY="$(cat)"
TMP=""
HAVE_LOCK=0
cleanup() {
  [ -n "$TMP" ] && rm -f "$TMP"
  [ "$HAVE_LOCK" = 1 ] && rmdir "$LOCK" 2>/dev/null
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# замок: до ~30 с (300 × 0,1 с); замок старше 2 минут считаем брошенным (убитый процесс)
i=0
until mkdir "$LOCK" 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -ge 300 ]; then echo "запись.sh: ящик $TO занят больше 30 с (замок $LOCK)" >&2; exit 2; fi
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then rmdir "$LOCK" 2>/dev/null || true; fi
  sleep 0.1
done
HAVE_LOCK=1

STAMP="$(TZ="${LAB_TZ:-UTC}" date '+%d.%m.%Y %H:%M')"
TMP="$(mktemp "$BOX.XXXXXX")"
{ sed -n '1,3p' "$BOX"; printf '\n## от %s, %s — %s\n\n%s\n\n' "$FROM" "$STAMP" "$TOPIC" "$BODY"; sed '1,3d' "$BOX" | sed '/./,$!d'; } > "$TMP"
mv "$TMP" "$BOX"; TMP=""

cd "$ROOT"
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "записано: $TO, $STAMP (корень не git-репозиторий: без коммита)"
  exit 0
fi
GIT_ID=""
if [ -z "$(git config user.email 2>/dev/null)" ] || [ -z "$(git config user.name 2>/dev/null)" ]; then
  GIT_ID="-c user.name=lab -c user.email=lab.invalid"
fi
n=0
# shellcheck disable=SC2086
until git add -- "$REL" 2>/dev/null && git $GIT_ID commit -q -m "Ящик $TO: $FROM — $TOPIC" -- "$REL" 2>/dev/null; do
  n=$((n + 1))
  if [ "$n" -ge 40 ]; then
    echo "запись.sh: коммит не прошёл (index.lock?). Запись лежит в $REL без коммита." >&2
    exit 3
  fi
  sleep 0.25
done
echo "записано: $TO, $STAMP"
