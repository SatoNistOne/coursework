# bookcrossing-db

Реляционная БД для сервиса буккроссинга. PostgreSQL 14+, схема в 3NF.

## Что это и зачем

База данных для книгообмена. Участники регистрируют книги, оставляют их в точках обмена (кафе, библиотеки), другие забирают и передают дальше. Система хранит полную историю перемещений каждого экземпляра, считает рейтинги участников и ведёт аудит смены статусов.

## ИИ-инструменты

По требованию методички документирую использование нейросетей:

- **Kandinsky** (https://fusionbrain.ai) — ER-диаграмма (файл `erd.png`)
- **Yandex GPT** (https://ya.ru/ai) — тексты отзывов и заметок к передачам для заполнения `data.sql`

Всё сгенерированное проверял и правил вручную. Основной код (DDL, PL/pgSQL, SQL-запросы) и текстовая часть курсовой написаны мной.

## Структура репозитория

| Файл | Содержимое |
|------|-----------|
| `schema.sql` | Таблицы, типы, роли, индексы |
| `procedures.sql` | Представления, функции, процедуры, триггеры |
| `data.sql` | Тестовые данные (22 передачи, 12 отзывов) |
| `queries.sql` | 18 типовых запросов |
| `dump.sql` | Всё в одном файле |
| `erd.png` | ER-диаграмма |
| `README.md` | Этот файл |

## Технические требования

- PostgreSQL 14 или выше
- Кодировка UTF-8 (база и файлы)
- Права суперпользователя (или `CREATEROLE`) для создания ролей
- ОС: Linux / macOS / Windows

## Установка

```bash
createdb -U postgres -E UTF8 bookcrossing

# Вариант 1: одним файлом
psql -U postgres -d bookcrossing -f dump.sql

# Вариант 2: по порядку
psql -U postgres -d bookcrossing -f schema.sql
psql -U postgres -d bookcrossing -f procedures.sql
psql -U postgres -d bookcrossing -f data.sql
```

> **Порядок важен:** `procedures.sql` идёт после `schema.sql` (триггеры должны существовать до вставки данных), а `data.sql` — после `procedures.sql`.

## Типовые запросы

1. Доступные книги в городе (через `v_available_books`)
2. Маршрут экземпляра (через `fn_book_journey`)
3. Топ-5 самых путешествующих книг (`GROUP BY + COUNT`)
4. Книги автора, доступные сейчас
5. Профиль участника (через `v_user_activity`)
6. «Зависшие» экземпляры — не двигались > 30 дней (`HAVING + INTERVAL`)
7. Рейтинг точек обмена по активности
8. Двусторонние участники (тройной CTE)
9. Ранжирование внутри города (`RANK`, `AVG OVER PARTITION BY`)
10. Динамика передач по месяцам (`LAG`, рост в процентах)
11. Статистика состояний экземпляров (`ARRAY_POSITION`, `SUM OVER`)
12. Самые популярные книги по уникальным читателям
13. Среднее время хранения книги у читателя (`LEAD`, CTE)
14. Популярность жанров по числу читателей
15. Книги, которые никто не взял (`NOT EXISTS`)
16. Репутационная карточка всех участников (через `v_user_reputation`)
17. Кому разрешено брать и регистрировать книги (`CROSS JOIN LATERAL fn_can_user_participate`)
18. Кто ухудшал состояние книг (`LATERAL JOIN`, `ARRAY_POSITION`)

Полный код запросов — в файле `queries.sql`.

## Проверка работоспособности

```sql
SELECT id, unique_code, status, current_holder FROM book_copies WHERE id = 1;
SELECT id, username, rating FROM users ORDER BY rating DESC;
SELECT * FROM copy_status_log ORDER BY changed_at DESC;
SELECT * FROM fn_book_journey('BC-2024-0001');
```

## Тестовые данные

| Таблица | Записей |
|---------|---------|
| `users` | 6 |
| `books` | 7 |
| `authors` | 7 |
| `genres` | 6 |
| `book_copies` | 10 |
| `drop_points` | 6 (5 активных, 1 неактивная) |
| `transfers` | 22 (включая первичный выпуск) |
| `reviews` | 12 |

Период: сентябрь 2024 — февраль 2025.

## Роли и права доступа

| Роль | SELECT | INSERT | UPDATE | DELETE | TRUNCATE | EXECUTE |
|------|--------|--------|--------|--------|----------|---------|
| `bc_admin` | все | все | все | все | все | все |
| `bc_moderator` | все | `drop_points` | `book_copies`, `drop_points` | `drop_points`, `reviews` | — | все |
| `bc_user` | книги, точки, передачи, отзывы | `book_copies`, `transfers`, `reviews` | `status`/`holder` в `book_copies` | — | — | `fn_*` |

Переключение между ролями для тестирования:

```sql
SET ROLE bc_user;
-- ... выполнение операций ...
RESET ROLE;
```

## Хранимые объекты

### Представления

- **`v_available_books`** — свободные экземпляры с авторами, жанрами, точкой обмена
- **`v_user_activity`** — сводная статистика активности участников
- **`v_user_reputation`** — репутационная карточка: активность, сохранность книг, своевременность, статус доступа

### Функции

- **`fn_user_rating(user_id)`** — взвешенный рейтинг: 40% отзывы + 25% сохранность + 20% своевременность + 15% активность
- **`fn_book_journey(unique_code)`** — табличная функция, возвращает полный маршрут экземпляра с интервалами (`LAG`)
- **`fn_can_user_participate(user_id)`** — возвращает статус участника и доступные операции на основе рейтинга

### Процедуры

- **`sp_transfer_book(...)`** — передача экземпляра: транзакция, проверки (в т.ч. активность точки обмена), типизированный обработчик ошибок
- **`sp_mark_copy_lost(...)`** — пометить экземпляр утерянным: проверяет, что инициатор — текущий держатель или модератор/администратор; снимает держателя, запускает аудит

### Триггеры

- **`trg_before_transfer_insert`** — `BEFORE INSERT on transfers`: авто-заполнение `condition_at_transfer`
- **`trg_after_transfer_insert`** — `AFTER INSERT on transfers`: обновляет `book_copies`, пересчитывает рейтинг отправителя
- **`trg_after_review_insert`** — `AFTER INSERT on reviews`: пересчитывает рейтинг автора книги
- **`trg_log_status_change`** — `AFTER UPDATE OF status on book_copies`: пишет в `copy_status_log`

## Примеры вызова

```sql
-- Передать книгу через точку обмена
CALL sp_transfer_book(1, 1, 3, 1, 'Передача через библиотеку');

-- Прямая передача без точки обмена
CALL sp_transfer_book(2, 2, 4, NULL, 'Прямая передача');

-- Пометить экземпляр утерянным
CALL sp_mark_copy_lost(9, 4, 'Потерял во время переезда');
```

## Если что-то не работает

| Ошибка | Причина | Решение |
|--------|---------|---------|
| `function does not exist` | Файлы выполнены в неправильном порядке | `schema.sql` → `procedures.sql` → `data.sql` |
| `role already exists` | Роли уже созданы | Скрипт использует `IF NOT EXISTS`, можно игнорировать |
| `permission denied` | Недостаточно прав | Выполните от имени `postgres` или суперпользователя |
| Ошибка кодировки | База создана не в UTF-8 | `createdb -E UTF8 bookcrossing` |

## Удаление базы данных

```bash
dropdb -U postgres bookcrossing
psql -U postgres -c "DROP ROLE IF EXISTS bc_admin;"
psql -U postgres -c "DROP ROLE IF EXISTS bc_moderator;"
psql -U postgres -c "DROP ROLE IF EXISTS bc_user;"
```