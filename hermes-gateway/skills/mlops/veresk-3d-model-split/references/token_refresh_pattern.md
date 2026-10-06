# Google OAuth — паттерн автообновления токена

## Паттерн: refresh_token() при старте + при 401

## Проблема
Access token живёт ~1 час. Если скрипт запускается редко или долго работает — токен истёкает, запросы возвращают 401.

## Решение: двойная защита

### 1. Обнови при старте (proactive)
```python
with open(TOKEN_PATH) as f:
    tok = json.load(f)

def headers():
    return {"Authorization": f"Bearer {tok['access_token']}"}

def refresh_token():
    data = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": tok["refresh_token"],
        "client_id": tok["client_id"],
        "client_secret": tok["client_secret"],
    }).encode()
    req = urllib.request.Request(
        "https://oauth2.googleapis.com/token", data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"}, method="POST"
    )
    with urllib.request.urlopen(req) as r:
        resp = json.load(r)
        tok["access_token"] = resp["access_token"]
        # refresh_token может обновиться — сохраняй новый
        if "refresh_token" in resp:
            tok["refresh_token"] = resp["refresh_token"]
        with open(TOKEN_PATH, "w") as f:
            json.dump(tok, f, indent=2)

# ВАЖНО: вызывай ПОСЛЕ определения функции, ДО первых запросов
refresh_token()
```

### 2. Обнови при 401 (reactive)
```python
def upload_file(...):
    # ... формируем запрос ...
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)["id"]
    except urllib.error.HTTPError as e:
        if e.code == 401:
            refresh_token()  # обновили токен
            h = headers()    # новые заголовки с новым токеном
            h["Content-Type"] = f"multipart/related; boundary={boundary}"
            h["Content-Length"] = str(len(body))
            req = urllib.request.Request(url, data=body, headers=h, method="POST")
            with urllib.request.urlopen(req) as r:
                return json.load(r)["id"]
        raise
```

## Полный пример
```python
import os, json, urllib.request, urllib.parse

TOKEN_PATH = "/opt/data/google_token.json"

with open(TOKEN_PATH) as f:
    tok = json.load(f)

def headers():
    return {"Authorization": f"Bearer {tok['access_token']}"}

def refresh_token():
    data = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": tok["refresh_token"],
        "client_id": tok["client_id"],
        "client_secret": tok["client_secret"],
    }).encode()
    req = urllib.request.Request(
        "https://oauth2.googleapis.com/token", data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"}, method="POST"
    )
    with urllib.request.urlopen(req) as r:
        resp = json.load(r)
        tok["access_token"] = resp["access_token"]
        if "refresh_token" in resp:
            tok["refresh_token"] = resp["refresh_token"]
        with open(TOKEN_PATH, "w") as f:
            json.dump(tok, f, indent=2)

# 1. Proactive refresh при старте
refresh_token()

# 2. Используй headers() везде — он всегда вернёт свежий токен
def api_request(url, data=None, method="GET"):
    req = urllib.request.Request(url, data=data, headers=headers(), method=method)
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 401:
            refresh_token()
            req = urllib.request.Request(url, data=data, headers=headers(), method=method)
            with urllib.request.urlopen(req) as r:
                return json.load(r)
        raise
```

## Ловушка: повторный запрос после refresh должен использовать БАЗОВЫЙ url

Самая частая причина «401 не лечится, хотя `refresh_token()` отработал».

Если helper сам склеивает query-параметры с URL, то передача в ретрай
**уже склеенного** `full_url` продублирует параметры — запрос уйдёт с
`?q=...&pageSize=200&q=...&pageSize=200` и снова вернёт 401.

```python
# ❌ НЕВЕРНО — параметры склеиваются дважды
def _get_json(url, params=None, retry=True):
    if params:
        url = url + "?" + urllib.parse.urlencode(params)   # мутация параметра!
    req = urllib.request.Request(url, headers=_hdrs(), method="GET")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 401 and retry:
            refresh_token()
            return _get_json(url, params, retry=False)    # url уже с параметрами
        raise
```

```python
# ✅ ВЕРНО — склейка в отдельную переменную, ретрай с базовым url + params
def _get_json(url, params=None, retry=True):
    full_url = url + "?" + urllib.parse.urlencode(params) if params else url
    req = urllib.request.Request(full_url, headers=_hdrs(), method="GET")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 401 and retry:
            refresh_token()
            return _get_json(url, params, retry=False)    # базовый url + params
        body = ""
        try:
            body = e.read().decode()[:600]
        except Exception:
            pass
        raise RuntimeError("Drive API %s: HTTP %s %s" % (full_url[:140], e.code, body))
```

**Как диагностировать:** `refresh_token()` возвращает `expires_in: 3599` и
`GET /drive/v3/about` отвечает успешно, а `files.list` всё равно 401 →
почти наверняка дублирование параметров. Проверь, не мутируется ли параметр `url`.

Токен в файле может выглядеть валидным, но быть протухшим — поэтому `headers()`
должна быть **функцией**, читающей `tok['access_token']` каждый раз, а не
словарём, собранным один раз при импорте.

## Ключевые моменты
1. **`refresh_token()` после определения, до работы** — proactive
2. **`headers()` — функция, а не словарь** — всегда читает актуальный `tok['access_token']`
3. **При 401: refresh → retry** — reactive fallback, и ретрай идёт с **базовым** url
4. **Сохраняй новый refresh_token** — он может ротироваться
5. **Проверяй доступ через `GET /drive/v3/about?fields=user`** — отделяет
   «токен протух» от «нет доступа к папке»