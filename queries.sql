SELECT copy_id, unique_code, title, authors, genres, condition,
    drop_point_name, drop_point_address
FROM v_available_books
WHERE city = 'Москва'
ORDER BY title;

SELECT step_number AS "Шаг",
    to_char(transfer_date, 'DD.MM.YYYY') AS "Дата",
    from_user AS "От кого", to_user AS "Кому",
    drop_point AS "Точка обмена", city AS "Город",
    days_in_hands AS "Дней у предыдущего"
FROM fn_book_journey('BC-2024-0001');

SELECT b.title,
    STRING_AGG(DISTINCT a.last_name, ', ') AS authors,
    COUNT(t.id) AS transfers_total,
    COUNT(DISTINCT bc.id) AS copies_in_circulation
FROM books b
JOIN book_copies bc ON b.id = bc.book_id
JOIN transfers t ON bc.id = t.copy_id
LEFT JOIN book_authors ba ON b.id = ba.book_id
LEFT JOIN authors a ON ba.author_id = a.id
GROUP BY b.id, b.title
ORDER BY transfers_total DESC, b.title
LIMIT 5;

SELECT copy_id, unique_code, title, condition,
    drop_point_name, drop_point_address, city
FROM v_available_books
WHERE authors ILIKE '%Булгаков%'
ORDER BY city, drop_point_name;

SELECT username, city,
    copies_registered AS "Зарегистрировано книг",
    copies_given AS "Отдано книг",
    copies_received AS "Получено книг",
    reviews_written AS "Написано отзывов",
    rating AS "Текущий рейтинг",
    TO_CHAR(last_active_at, 'DD.MM.YYYY') AS "Последняя активность"
FROM v_user_activity WHERE id = 1;

SELECT bc.unique_code AS "Код", b.title AS "Название",
    u.username AS "Держатель",
    TO_CHAR(MAX(t.transfer_date), 'DD.MM.YYYY') AS "Последняя передача",
    (NOW() - MAX(t.transfer_date))::TEXT AS "Простой"
FROM book_copies bc
JOIN books b ON bc.book_id = b.id
LEFT JOIN users u ON bc.current_holder = u.id
LEFT JOIN transfers t ON bc.id = t.copy_id
WHERE bc.status = 'taken'
GROUP BY bc.id, bc.unique_code, b.title, u.username
HAVING MAX(t.transfer_date) < NOW() - INTERVAL '30 days'
ORDER BY MAX(t.transfer_date);

SELECT dp.name AS "Точка", dp.city AS "Город",
    COUNT(t.id) AS "Всего передач",
    ROUND(COUNT(t.id)::NUMERIC / NULLIF(
        (DATE_PART('year', AGE(NOW(), MIN(t.transfer_date))) * 12
        + DATE_PART('month', AGE(NOW(), MIN(t.transfer_date))) + 1)::NUMERIC, 0), 1
    ) AS "Передач в месяц"
FROM drop_points dp
LEFT JOIN transfers t ON dp.id = t.drop_point_id
WHERE dp.is_active = TRUE
GROUP BY dp.id, dp.name, dp.city
ORDER BY COUNT(t.id) DESC;

WITH given AS (
    SELECT from_user_id AS user_id, COUNT(*) AS given_count
    FROM transfers WHERE from_user_id IS NOT NULL
    GROUP BY from_user_id
),
received AS (
    SELECT to_user_id AS user_id, COUNT(*) AS received_count
    FROM transfers GROUP BY to_user_id
),
combined AS (
    SELECT u.username, u.city, u.rating,
        COALESCE(g.given_count, 0) AS given,
        COALESCE(r.received_count, 0) AS received,
        COALESCE(g.given_count, 0) + COALESCE(r.received_count, 0) AS total_activity
    FROM users u
    LEFT JOIN given g ON g.user_id = u.id
    LEFT JOIN received r ON r.user_id = u.id
)
SELECT username, city, given AS "Отдано", received AS "Получено",
    total_activity AS "Всего операций",
    ROUND(given::NUMERIC / NULLIF(received, 0), 2) AS "Коэф. give/receive",
    rating AS "Рейтинг"
FROM combined WHERE total_activity > 0
ORDER BY total_activity DESC;

SELECT username AS "Участник", city AS "Город",
    rating AS "Рейтинг",
    RANK() OVER (PARTITION BY city ORDER BY rating DESC) AS "Место в городе",
    ROUND(AVG(rating) OVER (PARTITION BY city), 2) AS "Средний рейтинг города",
    COUNT(*) OVER (PARTITION BY city) AS "Участников в городе"
FROM users
ORDER BY city, "Место в городе";

WITH monthly AS (
    SELECT DATE_TRUNC('month', transfer_date)::DATE AS month,
        COUNT(*) AS transfers
    FROM transfers GROUP BY DATE_TRUNC('month', transfer_date)
)
SELECT TO_CHAR(month, 'YYYY-MM') AS "Месяц",
    transfers AS "Передач",
    LAG(transfers) OVER (ORDER BY month) AS "Передач (пред. месяц)",
    transfers - LAG(transfers) OVER (ORDER BY month) AS "Изменение",
    CASE WHEN LAG(transfers) OVER (ORDER BY month) IS NULL THEN '—'
        ELSE ROUND((transfers - LAG(transfers) OVER (ORDER BY month))::NUMERIC
            / LAG(transfers) OVER (ORDER BY month) * 100, 1)::TEXT || '%'
    END AS "Рост, %"
FROM monthly ORDER BY month;

SELECT condition::TEXT AS "Состояние",
    COUNT(*) AS "Экземпляров",
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS "Доля, %",
    STRING_AGG(DISTINCT status::TEXT, ', ' ORDER BY status::TEXT) AS "Статусы в группе"
FROM book_copies
GROUP BY condition
ORDER BY ARRAY_POSITION(ARRAY['new','good','fair','poor'], condition::TEXT);

SELECT b.title AS "Книга",
    STRING_AGG(DISTINCT a.last_name, ', ') AS "Авторы",
    COUNT(DISTINCT t.to_user_id) AS "Уникальных читателей",
    COUNT(t.id) AS "Всего передач",
    ROUND(COUNT(t.id)::NUMERIC / NULLIF(COUNT(DISTINCT bc.id), 0), 1) AS "Передач на экземпляр"
FROM books b
JOIN book_copies bc ON b.id = bc.book_id
LEFT JOIN transfers t ON bc.id = t.copy_id
LEFT JOIN book_authors ba ON b.id = ba.book_id
LEFT JOIN authors a ON ba.author_id = a.id
GROUP BY b.id, b.title
HAVING COUNT(t.id) > 0
ORDER BY "Уникальных читателей" DESC, "Всего передач" DESC;

WITH durations AS (
    SELECT bc.id AS copy_id, b.title, t.to_user_id,
        t.transfer_date AS received_at,
        LEAD(t.transfer_date) OVER (PARTITION BY bc.id ORDER BY t.transfer_date, t.id) AS given_away_at,
        DATE_PART('day',
            LEAD(t.transfer_date) OVER (PARTITION BY bc.id ORDER BY t.transfer_date, t.id)
            - t.transfer_date) AS days_held
    FROM transfers t
    JOIN book_copies bc ON t.copy_id = bc.id
    JOIN books b ON bc.book_id = b.id
)
SELECT title AS "Книга",
    ROUND(AVG(days_held)::NUMERIC, 1) AS "Среднее дней у читателя",
    MIN(days_held)::INTEGER AS "Минимум дней",
    MAX(days_held)::INTEGER AS "Максимум дней",
    COUNT(days_held) AS "Измеренных интервалов"
FROM durations WHERE days_held IS NOT NULL
GROUP BY title ORDER BY "Среднее дней у читателя";

SELECT g.name AS "Жанр",
    COUNT(DISTINCT b.id) AS "Книг в жанре",
    COUNT(DISTINCT bc.id) AS "Экземпляров",
    COUNT(DISTINCT t.to_user_id) AS "Уникальных читателей",
    COUNT(t.id) AS "Всего передач"
FROM genres g
JOIN book_genres bg ON g.id = bg.genre_id
JOIN books b ON bg.book_id = b.id
JOIN book_copies bc ON b.id = bc.book_id
LEFT JOIN transfers t ON bc.id = t.copy_id
GROUP BY g.id, g.name
ORDER BY "Уникальных читателей" DESC;

SELECT bc.unique_code AS "Код", b.title AS "Название",
    STRING_AGG(DISTINCT a.last_name, ', ') AS "Авторы",
    u.username AS "Зарегистрировал", u.city AS "Город",
    TO_CHAR(bc.registered_at, 'DD.MM.YYYY') AS "Дата регистрации",
    (NOW() - bc.registered_at)::TEXT AS "Ждёт"
FROM book_copies bc
JOIN books b ON bc.book_id = b.id
JOIN users u ON bc.registered_by = u.id
LEFT JOIN book_authors ba ON b.id = ba.book_id
LEFT JOIN authors a ON ba.author_id = a.id
WHERE bc.status = 'available'
  AND NOT EXISTS (SELECT 1 FROM transfers t WHERE t.copy_id = bc.id)
GROUP BY bc.id, bc.unique_code, b.title, u.username, u.city, bc.registered_at
ORDER BY bc.registered_at;

SELECT username AS "Участник", city AS "Город", rating AS "Рейтинг",
    account_status AS "Статус",
    books_given AS "Отдано", books_received AS "Получено",
    avg_days_held AS "Ср. дней хранения",
    avg_cond_change AS "Ср. изменение состояния",
    books_damaged AS "Повреждено книг",
    overdue_count AS "Просрочек (>90 дней)"
FROM v_user_reputation ORDER BY rating;

SELECT u.username AS "Участник", u.city AS "Город", u.rating AS "Рейтинг",
    p.can_receive AS "Может получить",
    p.can_register AS "Может зарегистрировать",
    p.account_status AS "Статус аккаунта",
    p.reason AS "Причина"
FROM users u
CROSS JOIN LATERAL fn_can_user_participate(u.id) p
ORDER BY u.rating DESC;

WITH cond_history AS (
    SELECT t_out.from_user_id AS user_id,
        bc.unique_code, b.title,
        t_prev.condition_at_transfer::TEXT AS received_as,
        t_out.condition_at_transfer::TEXT AS returned_as,
        ARRAY_POSITION(ARRAY['poor','fair','good','new']::TEXT[], t_out.condition_at_transfer::TEXT)
        - ARRAY_POSITION(ARRAY['poor','fair','good','new']::TEXT[], t_prev.condition_at_transfer::TEXT) AS delta
    FROM transfers t_out
    JOIN LATERAL (
        SELECT condition_at_transfer, to_user_id FROM transfers
        WHERE copy_id = t_out.copy_id AND id < t_out.id
        ORDER BY id DESC LIMIT 1
    ) t_prev ON t_prev.to_user_id = t_out.from_user_id
    JOIN book_copies bc ON t_out.copy_id = bc.id
    JOIN books b ON bc.book_id = b.id
    WHERE t_out.condition_at_transfer IS NOT NULL
      AND t_prev.condition_at_transfer IS NOT NULL
      AND ARRAY_POSITION(ARRAY['poor','fair','good','new']::TEXT[], t_out.condition_at_transfer::TEXT)
        < ARRAY_POSITION(ARRAY['poor','fair','good','new']::TEXT[], t_prev.condition_at_transfer::TEXT)
)
SELECT u.username AS "Участник", ch.title AS "Книга",
    ch.unique_code AS "Код", ch.received_as AS "Получил",
    ch.returned_as AS "Вернул", ch.delta AS "Изменение",
    u.rating AS "Текущий рейтинг"
FROM cond_history ch
JOIN users u ON ch.user_id = u.id
ORDER BY ch.delta, u.username;