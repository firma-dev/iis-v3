#!/bin/bash
# Установка шаблона лаборатории агентов.
#   bash install.sh [--корень DIR] [--роли a,b,c] [--проект DIR | --глобально]
#                   [--перезаписать] [--сухой] [--помощь]
#
# Корень лаборатории: --корень, иначе переменная LAB_ROOT, иначе $HOME/lab.
# Роли по умолчанию: разработчик,ревьюер,исследователь,чекер. Ящики создаются всегда
# для четырёх стандартных ролей, для переданных в --роли и для «ведущего» (главная
# сессия) и «владельца» (человек): на них ссылается протокол. Агенты
# (.claude/agents/<роль>.md):
#   --проект DIR  -> DIR/.claude/agents   (агенты видны в этом проекте)
#   --глобально   -> $HOME/.claude/agents (видны везде)
#   без флага     -> <корень>/.claude/agents (запускай Claude Code из корня лаборатории)
# Файл настроек (settings.json) скрипт НЕ правит: он печатает кусок JSON с хуком,
# вставляешь его сам. --сухой — ничего не писать, только показать, что будет сделано.
# Переменные латиницей: bash принимает кириллицу в именах нестабильно.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
LAB="${LAB_ROOT:-$HOME/lab}"
ROLES="разработчик,ревьюер,исследователь,чекер"
MODE="lab"        # lab | project | global
PROJECT=""
DRY=0
FORCE=0

usage() { sed -n '2,/^set -eu/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --корень)       [ "$#" -ge 2 ] || { echo "--корень требует путь" >&2; exit 64; }; LAB="$2"; shift 2;;
    --роли)         [ "$#" -ge 2 ] || { echo "--роли требует список" >&2; exit 64; }; ROLES="$2"; shift 2;;
    --проект)       [ "$#" -ge 2 ] || { echo "--проект требует путь" >&2; exit 64; }; MODE="project"; PROJECT="$2"; shift 2;;
    --глобально)    MODE="global"; shift;;
    --перезаписать) FORCE=1; shift;;
    --сухой)        DRY=1; shift;;
    --помощь|-h|--help) usage; exit 0;;
    *) echo "install.sh: неизвестный аргумент: $1" >&2; usage >&2; exit 64;;
  esac
done

# абсолютный путь корня (каталога может ещё не быть)
case "$LAB" in
  /*) ;;
  *) LAB="$PWD/$LAB";;
esac
case "$LAB" in
  *"|"*|*"&"*|*"\\"*|*"'"*|*'"'*) echo "install.sh: в пути корня недопустимы | & \\ ' \"" >&2; exit 64;;
esac

say() { printf '%s\n' "$*"; }
act() { if [ "$DRY" = 1 ]; then say "[сухой] $*"; else say "$*"; fi; }

# роли: имена без слэшей, пробельных символов и знаков шаблонов (* ? [); set -f — без раскрытия имён
ROLE_LIST=""
OLD_IFS="$IFS"; IFS=','
set -f
for r in $ROLES; do
  case "$r" in ""|*/*|*" "*|.*|*"*"*|*"?"*|*"["*) echo "install.sh: недопустимое имя роли: '$r'" >&2; exit 64;; esac
  case "$r" in ведущий|владелец) continue;; esac   # эти ящики есть всегда
  case " $ROLE_LIST " in *" $r "*) continue;; esac
  ROLE_LIST="$ROLE_LIST $r"
done
set +f
IFS="$OLD_IFS"
[ -n "$ROLE_LIST" ] || { echo "install.sh: список ролей пуст" >&2; exit 64; }
ROLE_LIST="${ROLE_LIST# }"
# ящики: четыре стандартные роли, переданные роли, ведущий, владелец (без повторов)
BOX_LIST="разработчик ревьюер исследователь чекер"
for r in $ROLE_LIST; do
  case " $BOX_LIST " in *" $r "*) ;; *) BOX_LIST="$BOX_LIST $r";; esac
done
BOX_LIST="$BOX_LIST ведущий владелец"

case "$MODE" in
  lab)     AGENTS_DIR="$LAB/.claude/agents";;
  project) case "$PROJECT" in /*) ;; *) PROJECT="$PWD/$PROJECT";; esac; AGENTS_DIR="$PROJECT/.claude/agents";;
  global)  AGENTS_DIR="$HOME/.claude/agents";;
esac

say "Корень лаборатории: $LAB"
say "Роли (агенты): $ROLE_LIST"
say "Ящики: $BOX_LIST"
say "Агенты -> $AGENTS_DIR"
[ "$DRY" = 1 ] && say "Режим: сухой (ничего не записывается)"
command -v python3 >/dev/null 2>&1 || say "ВНИМАНИЕ: python3 не найден, хук-потолок работать не будет"
command -v git >/dev/null 2>&1 || say "ВНИМАНИЕ: git не найден, запись.sh не сможет коммитить"
say ""

mk() { act "каталог $1"; [ "$DRY" = 1 ] || mkdir -p "$1"; }

# 1. каталоги
for d in "связь/ящики" "связь/передачи" "связь/скрипты" "инструменты" "память" "проекты" "качество"; do mk "$LAB/$d"; done

# 2. ящики и память
for r in $BOX_LIST; do
  box="$LAB/связь/ящики/$r.md"
  if [ -e "$box" ]; then act "ящик $r уже есть (оставлен)"; else
    act "ящик $r"
    [ "$DRY" = 1 ] || printf '# Ящик: %s\n\nНовое сверху.\n' "$r" > "$box"
  fi
done
for r in $ROLE_LIST ведущий; do
  mem="$LAB/память/$r.md"
  if [ -e "$mem" ]; then act "память $r уже есть (оставлена)"; else
    act "память $r (заготовка)"
    [ "$DRY" = 1 ] || printf '# Память: %s\n\n## Уроки\n' "$r" > "$mem"
  fi
done

# 3. скрипты, протокол, ворота
put() {   # put <откуда> <куда> [режим]
  if [ -e "$2" ] && [ "$FORCE" = 0 ] && cmp -s "$1" "$2"; then act "уже на месте: $2"; return; fi
  act "копирую $(basename "$1") -> $2"
  [ "$DRY" = 1 ] || { cp "$1" "$2"; [ -z "${3:-}" ] || chmod "$3" "$2"; }
}
putsub() {   # putsub <откуда> <куда>: копия с подстановкой {{LAB_ROOT}}
  if [ -e "$2" ] && [ "$FORCE" = 0 ] && sed "s|{{LAB_ROOT}}|$LAB|g" "$1" | cmp -s - "$2"; then act "уже на месте: $2"; return; fi
  act "копирую $(basename "$1") -> $2 (с корнем лаборатории)"
  [ "$DRY" = 1 ] || sed "s|{{LAB_ROOT}}|$LAB|g" "$1" > "$2"
}
put "$HERE/скрипты/запись.sh"       "$LAB/связь/скрипты/запись.sh" 755
put "$HERE/скрипты/сдать.sh"        "$LAB/связь/скрипты/сдать.sh" 755
put "$HERE/скрипты/хук-потолок.py"  "$LAB/инструменты/хук-потолок.py" 755
# протокол и ворота: {{LAB_ROOT}} подставляется корнем, как в агентах
putsub "$HERE/протокол.md"          "$LAB/связь/протокол.md"
putsub "$HERE/ворота.md"            "$LAB/ворота.md"

# 4. git в корне (запись.sh коммитит ящики)
if [ -e "$LAB/.git" ]; then
  act "git: корень уже в репозитории"
else
  act "git init в $LAB и первый коммит"
  if [ "$DRY" = 0 ]; then
    git -C "$LAB" init -q -b main 2>/dev/null || { git -C "$LAB" init -q && git -C "$LAB" symbolic-ref HEAD refs/heads/main; }
    ID=""
    if [ -z "$(git -C "$LAB" config user.email 2>/dev/null)" ] || [ -z "$(git -C "$LAB" config user.name 2>/dev/null)" ]; then
      ID="-c user.name=lab -c user.email=lab.invalid"
    fi
    git -C "$LAB" add -- связь инструменты память ворота.md
    # shellcheck disable=SC2086
    git -C "$LAB" $ID commit -q -m "Лаборатория: начальное состояние" || say "ВНИМАНИЕ: первый коммит не прошёл (настрой git user.name/user.email)"
  fi
fi

# 5. агенты
act "каталог $AGENTS_DIR"
[ "$DRY" = 1 ] || mkdir -p "$AGENTS_DIR"
for r in $ROLE_LIST; do
  src="$HERE/.claude/agents/$r.md"
  dst="$AGENTS_DIR/$r.md"
  if [ ! -f "$src" ]; then act "агент $r: в шаблоне нет файла (только ящик и память)"; continue; fi
  if [ -e "$dst" ] && [ "$FORCE" = 0 ]; then act "агент $r уже есть в $AGENTS_DIR (оставлен; --перезаписать заменит)"; continue; fi
  act "агент $r -> $dst"
  [ "$DRY" = 1 ] || sed "s|{{LAB_ROOT}}|$LAB|g" "$src" > "$dst"
done

# 6. кусок JSON для настроек
HOOK="$LAB/инструменты/хук-потолок.py"
say ""
say "Готово$([ "$DRY" = 1 ] && echo ' (сухой прогон: ничего не записано)')."
say ""
say "Хук-потолок скрипт НЕ подключает сам. Вставь этот кусок в файл настроек Claude Code"
say "(~/.claude/settings.json для всех проектов или <проект>/.claude/settings.json), слив с уже"
say "имеющимся ключом \"hooks\", если он есть:"
say ""
cat <<JSON
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "python3 -I '$HOOK'" }
        ]
      }
    ]
  }
}
JSON
say ""
say "Проверка хука:  python3 -I '$HOOK' --проверка"
say "Первая запись:  echo 'привет' | LAB_ROOT='$LAB' sh '$LAB/связь/скрипты/запись.sh' владелец ведущий 'проверка связи'"
say "Часовой пояс записей: по умолчанию UTC; свой — переменная LAB_TZ (например LAB_TZ=Europe/Berlin), см. протокол, «Время и подвохи»."
say ""
say "Главной сессии (ведущему) дай прочитать $LAB/связь/протокол.md и $LAB/ворота.md;"
say "роли зовёт ведущий. Перед новым проектом — заполненные ворота (протокол, «Перед проектом»)."
