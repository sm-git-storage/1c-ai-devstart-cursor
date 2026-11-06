---
name: 1c-odata
description: "Чтение данных из информационной базы 1С:Предприятие, опубликованной по OData, по HTTP с Basic Auth (скрипт PowerShell). Запасной путь к данным: используй, только когда MCP-сервер 1С не подключён или не отвечает, либо пользователь прямо просит OData. Если MCP доступен, данные бери запросом через него (см. .cursor/rules/mcp.mdc и скилл mcp-1c). Отличие от соседей: этот скилл - чтение живых данных по HTTP без MCP; 1c-integrations - написание HTTP-клиентов/обменов в коде BSL."
---

# 1C OData Skill

Interact with a 1C:Enterprise database published via OData v3. All requests go through the PowerShell
script with Basic Auth; no MCP server, bash, curl or Node.js required.

**Windows note**: the script URL-encodes entity names and parameter values as UTF-8 and builds the
Basic Auth header in UTF-8, so Cyrillic names, filters and user names survive. Do not call raw `curl`
with Cyrillic in the URL. `scripts/odata_query.sh` is the same tool for bash on Linux/macOS.

## 1. Connection Setup

The script auto-loads `.env` from the current working directory; values from flags take precedence.

Expected `.env` format (template — `.env.example` next to this file):
```
ODATA_URL=http://localhost/DemoSSL_3_1_10_369/odata/standard.odata
ODATA_USER=Администратор
ODATA_PASSWORD=
```

If `.env` doesn't exist — ask the user for the URL and user name, and let the user fill in the password
in `.env` themselves (do not ask for it in chat).

## 2. Using the Query Script

The script `scripts/odata_query.ps1` handles encoding, auth, and all OData parameters. Always use it
instead of raw HTTP calls. Full command, run from the project root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .cursor/skills/1c-odata/scripts/odata_query.ps1 -e ENTITY_NAME [options]
```

Below, `odata` stands for `powershell -NoProfile -ExecutionPolicy Bypass -File .cursor/skills/1c-odata/scripts/odata_query.ps1`.

```powershell
# With .env auto-loaded (no -u/-p needed if .env is set):
odata -e ENTITY_NAME [options]

# Or with explicit URL and user:
odata -b "http://localhost/base/odata/standard.odata" -u "Администратор" -e ENTITY_NAME [options]
```

In PowerShell, quote values with `$` in single quotes (`'$metadata'`), otherwise the shell expands them.

Key flags:
| Flag | OData param | Example |
|------|------------|---------|
| `-e` | entity name | `-e "Catalog__ДемоНоменклатура"` |
| `-t` | `$top` | `-t 20` |
| `-k` | `$skip` | `-k 40` |
| `-s` | `$select` | `-s "Ref_Key,Description,Code"` |
| `-f` | `$filter` | `-f "DeletionMark eq false"` |
| `-o` | `$orderby` | `-o "Date desc"` |
| `-x` | `$expand` | `-x "Document__ДемоРеализация_Товары"` |
| `-F` | `$format` | `-F xml` |
| `--count` | `/$count` endpoint | returns a plain integer |
| `--inline-count` | `$inlinecount=allpages` | count + records together |
| `--out` | — | `--out "$env:TEMP\data.json"` — save the response as UTF-8 |

## 3. Discovering Available Entities

**Start here** — not all 1C objects are published. Only what the administrator explicitly enabled is accessible.

```powershell
# List published entities (no -e = service root)
odata
```

The response is JSON with a `value` array. Entity names tell you what's available.

If the entity you need is missing, tell the user: *"Entity X is not published in this OData service. Ask the administrator to add it in Администрирование → Публикация на веб-сервере → вкладка OData."*

**Get full schema (field names and types):**
```powershell
odata -e '$metadata' -F xml
```
Look for `<EntityType Name="...">` sections and their `<Property>` children.

**Inspect one record to discover fields:**
```powershell
odata -e "EntityName" -t 1
```

## 4. 1C Entity Naming

| 1C Object Type | OData Prefix | Example |
|----------------|--------------|---------|
| Справочник | `Catalog_` | `Catalog_Контрагенты` |
| Документ | `Document_` | `Document_РеализацияТоваровУслуг` |
| Рег. сведений | `InformationRegister_` | `InformationRegister_ЦеныНоменклатуры` |
| Рег. накопления | `AccumulationRegister_` | `AccumulationRegister_Продажи` |
| Перечисление | `Enum_` | `Enum_ВидыНоменклатуры` |
| План счетов | `ChartOfAccounts_` | `ChartOfAccounts_Хозрасчетный` |

**Double-underscore rule**: if the object name starts with `_` (common in demo bases), OData name gets `__`:
- Object `_ДемоНоменклатура` → entity `Catalog__ДемоНоменклатура`

## 5. Query Patterns

### Filter examples

```powershell
# Active records only
-f "DeletionMark eq false"

# String contains
-f "substringof('Стол',Description)"

# String starts with
-f "startswith(Description,'ООО')"

# Date range
-f "Date ge datetime'2024-01-01T00:00:00' and Date le datetime'2024-12-31T23:59:59'"

# By GUID reference key
-f "Ref_Key eq guid'12345678-abcd-abcd-abcd-123456789012'"

# Boolean
-f "Posted eq true"
```

### Count records

```powershell
# Plain count (fastest)
odata -e "Catalog__ДемоНоменклатура" --count
# → 46

# Count with filter
odata -e "Catalog__ДемоНоменклатура" -f "DeletionMark eq false" --count
```

### Expand related entities (tabular parts)

```powershell
odata -e "Document__ДемоРеализация" -t 3 -x "Document__ДемоРеализация_Товары"
```

Tabular part naming: `DocumentEntityName_TablePartName` (e.g., `Document__ДемоРеализация_Товары`).

### Pagination

```powershell
-t 50 -k 0    # page 1
-t 50 -k 50   # page 2
-t 50 -k 100  # page 3
```

## 6. Parsing 1C-Specific Data Types

**Dates** — 1C returns `/Date(ms)/` format. Convert in PowerShell:
```powershell
[DateTimeOffset]::FromUnixTimeMilliseconds(1704067200000).UtcDateTime
```

Or for a batch of records (save the response with `--out` first):
```powershell
$d = [IO.File]::ReadAllText("$env:TEMP\data.json", [Text.Encoding]::UTF8) | ConvertFrom-Json
$d.value | ForEach-Object {
  $ms = [long]([regex]::Match($_.Date, '\d+').Value)
  '{0:dd.MM.yyyy} {1} {2}' -f [DateTimeOffset]::FromUnixTimeMilliseconds($ms).UtcDateTime, $_.Number, $_.СуммаДокумента
}
```

**GUIDs** — stored in `Ref_Key`, `*_Key` fields. Use in filter:
```
-f "НоменклатураRef_Key eq guid'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'"
```

**Enums** — stored as a URL string: `"ТипЦены_Key": "Enum_ТипЦен/ОсновнаяЦенаПродажи"`.

## 7. Analytical Workflow

When the user asks a business question about 1C data:

1. **Check what's published** — run `odata` without `-e` to see available entities.
2. **Identify the right entity** — documents/registers for operational data, catalogs for reference.
3. **Sample one record** to discover field names: `-t 1`
4. **Query with filters** — use `-s` to select only needed fields, `-f` to filter.
5. **Aggregate locally** — OData v3 has no server-side GROUP BY. Save the response with `--out`
   (not with `>`: in Windows PowerShell 5.1 `>` writes UTF-16) and aggregate in PowerShell:
   ```powershell
   odata -e EntityName -t 1000 --out "$env:TEMP\data.json"
   $d = [IO.File]::ReadAllText("$env:TEMP\data.json", [Text.Encoding]::UTF8) | ConvertFrom-Json
   'Итого: ' + ($d.value | Measure-Object -Property СуммаДокумента -Sum).Sum
   ```
6. **Present results** as a markdown table.

## 8. Error Reference

| Exit / HTTP code | Cause | Fix |
|-----------|-------|-----|
| HTTP 401 | Wrong credentials | Check ODATA_USER / ODATA_PASSWORD in .env |
| HTTP 403 | User lacks rights | Check 1C user roles for this entity |
| HTTP 404 | Wrong entity name | Run without `-e` to list published entities |
| HTTP 400 | Bad OData syntax | Check filter; escape single quotes as `''` |
| OData error -1 | Internal 1C error (transient) | Retry; check 1C technology log |
| exit 7 | Server unreachable | Check ODATA_URL and that the web server is running |
| Response is XML | `$format=json` not applied | The script adds it automatically |
| Entity not in list | Not published in OData | Ask administrator to publish it |

On an HTTP error the script prints the status line and the response body to stderr and exits with code 22.

**Debug raw response:** the script always prints the actual URL to stderr (`→ GET ...`). Don't append
`2>&1` in Windows PowerShell 5.1: it wraps every stderr line of a native command into an error record.
