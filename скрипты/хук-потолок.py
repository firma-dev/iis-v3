#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Хук Claude Code UserPromptSubmit «потолок контекста».

Если контекст главной сессии больше порога (по умолчанию 200 тыс. токенов), в ход
добавляется строка «контекст N тыс. > 200: пиши передачу в <корень>/связь/передачи/
и очищайся». При порог или меньше — молчит. Любая ошибка (нет файла, кривой JSON,
нет поля) — молчит, код 0.

Корень лаборатории: переменная LAB_ROOT, иначе родитель каталога, где лежит хук
(<корень>/инструменты/хук-потолок.py). Нужен Python 3.8+ (--проверка требует; сам хук проще). Порог: LAB_CEILING (токены, по умолчанию 200000).

Вход (stdin): JSON хука с полем transcript_path.
Контекст = последняя запись assistant стенограммы (не sidechain, сумма > 0):
  usage.input_tokens + usage.cache_read_input_tokens + usage.cache_creation_input_tokens.
Это контекст ПОСЛЕДНЕГО запроса модели: текущая реплика человека ещё не посчитана.
Стенограмма читается с конца блоками по 256 КБ, не больше 64 МБ.
Выход: JSON {"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"…"}}.

Самопроверка: python3 -I хук-потолок.py --проверка
Подключение (settings) — только рукой владельца: install.sh печатает кусок JSON.
"""
import json
import os
import sys

ПОРОГ_ПО_УМОЛЧАНИЮ = 200_000
БЛОК = 256 * 1024
МАКС_ЧТЕНИЕ = 64 * 1024 * 1024
МЕТКА_ТИПА = b'"assistant"'
МЕТКА_USAGE = b'"usage"'


def порог():
    try:
        return int(os.environ.get("LAB_CEILING") or ПОРОГ_ПО_УМОЛЧАНИЮ)
    except ValueError:
        return ПОРОГ_ПО_УМОЛЧАНИЮ


def корень():
    r = os.environ.get("LAB_ROOT")
    if r:
        return r
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def строка_для(всего, п, р):
    return f"контекст {всего // 1000} тыс. > {п // 1000}: пиши передачу в {р}/связь/передачи/ и очищайся"


def контекст(путь):
    """Токены контекста по последнему ответу модели или None."""
    with open(путь, "rb") as f:
        f.seek(0, 2)
        конец = f.tell()
        поз = конец
        хвост = b""          # неполная (левая) часть, ещё без начала строки
        прочитано = 0
        while поз > 0 and прочитано < МАКС_ЧТЕНИЕ:
            шаг = min(БЛОК, поз)
            поз -= шаг
            f.seek(поз)
            данные = f.read(шаг) + хвост
            прочитано += шаг
            строки = данные.split(b"\n")
            # строки[0] может быть обрезана слева, пока не дошли до начала файла
            хвост = строки[0] if поз > 0 else b""
            начало = 1 if поз > 0 else 0
            for i in range(len(строки) - 1, начало - 1, -1):
                s = строки[i]
                if МЕТКА_USAGE not in s or МЕТКА_ТИПА not in s:
                    continue
                try:
                    o = json.loads(s)
                    if o.get("type") != "assistant" or o.get("isSidechain"):
                        continue
                    u = o["message"]["usage"]
                    всего = sum(int(u.get(k) or 0) for k in
                                ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
                except Exception:
                    continue
                if всего > 0:
                    return всего
    return None


def главная():
    try:
        вход = json.loads(sys.stdin.read())
        путь = вход["transcript_path"]
        всего = контекст(путь)
        if всего is not None and всего > порог():
            текст = строка_для(всего, порог(), корень())
            sys.stdout.write(json.dumps({"hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit", "additionalContext": текст}}, ensure_ascii=False))
    except Exception:
        pass
    return 0


# ---------- самопроверка ----------
def _запись(вход, чтение, создание, **доп):
    o = {"type": "assistant", "isSidechain": False, "message": {"usage": {
        "input_tokens": вход, "cache_read_input_tokens": чтение,
        "cache_creation_input_tokens": создание, "output_tokens": 5}}}
    o.update(доп)
    return json.dumps(o, ensure_ascii=False)


def _запуск(вход_stdin, окружение=None):
    import subprocess
    import time
    env = dict(os.environ)
    for k in ("LAB_ROOT", "LAB_CEILING"):
        env.pop(k, None)           # проверка не зависит от окружения запустившего
    env.update(окружение or {})
    t = time.perf_counter()
    р = subprocess.run([sys.executable, "-I", os.path.abspath(__file__)], input=вход_stdin,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       universal_newlines=True, env=env)
    return р.returncode, р.stdout, time.perf_counter() - t


def корень_по_месту():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def проверка():
    if sys.version_info < (3, 8):
        print("--проверка: нужен Python 3.8 или новее, здесь %d.%d (сам хук работает и на более "
              "старом, но проверять его нечем)" % sys.version_info[:2], file=sys.stderr)
        return 2
    import tempfile
    import time
    ошибки = []

    def ждать(имя, условие, подробно=""):
        print(("ok   " if условие else "КРАСНО ") + имя + (" " + подробно if подробно else ""))
        if not условие:
            ошибки.append(имя)

    with tempfile.TemporaryDirectory() as d:
        def файл(имя, строки):
            p = os.path.join(d, имя)
            with open(p, "w", encoding="utf-8") as f:
                f.write("\n".join(строки) + "\n")
            return p

        def ход(p, окружение=None):
            return _запуск(json.dumps({"transcript_path": p, "hook_event_name": "UserPromptSubmit"}), окружение)

        # 1. больше порога: 2 + 594000 + 504 = 594506 -> «594»
        p = файл("big.jsonl", ['{"type":"user"}', _запись(1, 100, 1), _запись(2, 594000, 504)])
        к, в, _ = ход(p, {"LAB_ROOT": "/x/lab"})
        ок = False
        try:
            ок = json.loads(в)["hookSpecificOutput"]["additionalContext"] == \
                "контекст 594 тыс. > 200: пиши передачу в /x/lab/связь/передачи/ и очищайся" and к == 0
        except Exception:
            pass
        ждать("1 больше 200 тыс. -> строка с N и путём из LAB_ROOT", ок, repr(в[:120]))
        # 1а. без LAB_ROOT корень — родитель каталога хука
        к, в, _ = ход(p)
        ждать("1а без LAB_ROOT -> корень от места хука", к == 0 and
              корень_по_месту() + "/связь/передачи/" in в, repr(в[-100:]))
        # 1б. порог из LAB_CEILING
        p150 = файл("c150.jsonl", [_запись(1, 150000, 0)])
        к, в, _ = ход(p150, {"LAB_CEILING": "100000"})
        ждать("1б LAB_CEILING=100000, контекст 150 тыс. -> строка", к == 0 and "контекст 150 тыс. > 100" in в, repr(в[-100:]))
        к, в, _ = ход(p150)
        ждать("1в тот же файл при пороге по умолчанию -> пусто", к == 0 and в == "")
        # 2. ниже порога; ровно 200000 — тоже тишина
        к, в, _ = ход(файл("small.jsonl", [_запись(1, 100, 1), _запись(2, 150000, 500)]))
        ждать("2 меньше 200 тыс. -> пусто", к == 0 and в == "")
        к, в, _ = ход(файл("eq.jsonl", [_запись(0, 200000, 0)]))
        ждать("2а ровно 200000 -> пусто", к == 0 and в == "")
        # берётся последняя запись, а не максимум
        к, в, _ = ход(файл("after.jsonl", [_запись(1, 900000, 0), _запись(1, 80000, 0)]))
        ждать("2б после очистки (последняя запись мала) -> пусто", к == 0 and в == "")
        # sidechain и нулевые записи пропускаются
        к, в, _ = ход(файл("side.jsonl", [_запись(1, 300000, 0), _запись(1, 9, 0, isSidechain=True), _запись(0, 0, 0)]))
        ждать("2в sidechain и нули пропущены -> 300", к == 0 and "контекст 300 тыс." in в, repr(в[-90:]))
        # 3. сбои
        for имя, вход in (("нет файла", json.dumps({"transcript_path": os.path.join(d, "нет.jsonl")})),
                          ("кривой stdin", "{не json"), ("пустой stdin", ""),
                          ("нет поля transcript_path", "{}"),
                          ("transcript_path не строка", '{"transcript_path": 5}')):
            к, в, _ = _запуск(вход)
            ждать("3 " + имя + " -> пусто, код 0", к == 0 and в == "")
        к, в, _ = ход(файл("bad.jsonl", ["мусор", '{"type":"assistant","usage":1', _запись(1, 0, 0)]))
        ждать("3 кривая стенограмма / нет полей -> пусто, код 0", к == 0 and в == "")
        к, в, _ = ход(файл("nofield.jsonl", ['{"type":"assistant","message":{"usage":{"output_tokens":5}}}']))
        ждать("3 usage без полей токенов -> пусто, код 0", к == 0 and в == "")
        к, в, _ = ход(d)
        ждать("3 transcript_path — каталог -> пусто, код 0", к == 0 and в == "")
        # длинная строка (> блока) в хвосте, нужная запись глубже неё
        огромная = json.dumps({"type": "user", "message": {"content": "я" * (3 * БЛОК)}}, ensure_ascii=False)
        к, в, _ = ход(файл("longline.jsonl", [_запись(1, 250000, 0), огромная, огромная]))
        ждать("4 запись глубже длинных строк найдена -> 250", к == 0 and "контекст 250 тыс." in в)
        # 5. скорость: 50 МБ, нужная запись в конце; и худший случай — записи нет вовсе в последних 64 МБ не берём
        p = os.path.join(d, "50mb.jsonl")
        строка = json.dumps({"type": "user", "message": {"content": "x" * 3000}}) + "\n"
        with open(p, "w", encoding="utf-8") as f:
            f.write(_запись(1, 400000, 0) + "\n")
            for _ in range(50 * 1024 * 1024 // len(строка)):
                f.write(строка)
            f.write(_запись(3, 400000, 0) + "\n" + строка * 20)
        размер = os.path.getsize(p) >> 20
        лучшее = min(ход(p)[2] for _ in range(3))
        к, в, _ = ход(p)
        # порог провала 300 мс: на медленной машине или в контейнере запуск python сам занимает
        # десятки мс; выше 100 мс — только предупреждение
        ждать(f"5 стенограмма {размер} МБ: время ≤ 300 мс (с запуском python)", лучшее <= 0.3 and "контекст 400 тыс." in в,
              f"{лучшее * 1000:.0f} мс")
        if 0.1 < лучшее <= 0.3:
            print("     ПРЕДУПРЕЖДЕНИЕ: дольше 100 мс; хук работает, но машина медленная")
        # худший случай: подходящей записи нет вовсе — чтение ограничено 64 МБ
        p2 = os.path.join(d, "none.jsonl")
        with open(p2, "w", encoding="utf-8") as f:
            for _ in range(50 * 1024 * 1024 // len(строка)):
                f.write(строка)
        t = time.perf_counter()
        к, в, _ = ход(p2)
        print(f"     (справка) 50 МБ без единой записи assistant: {(time.perf_counter() - t) * 1000:.0f} мс, вывод пуст: {в == ''}")
    print("ПРОВЕРКА ПРОЙДЕНА" if not ошибки else "ПРОВЕРКА НЕ ПРОЙДЕНА: " + "; ".join(ошибки))
    return 0 if not ошибки else 1


if __name__ == "__main__":
    if "--проверка" in sys.argv[1:]:
        sys.exit(проверка())
    sys.exit(главная())
