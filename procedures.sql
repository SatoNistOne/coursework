DROP VIEW IF EXISTS v_user_reputation CASCADE;
DROP VIEW IF EXISTS v_user_activity CASCADE;
DROP VIEW IF EXISTS v_available_books CASCADE;

CREATE OR REPLACE VIEW v_available_books AS
SELECT
    bc.id AS copy_id,
    bc.unique_code,
    b.title,
    b.published_year,
    STRING_AGG(DISTINCT a.last_name || ' ' || a.first_name, ', ') AS authors,
    STRING_AGG(DISTINCT g.name, ', ') AS genres,
    bc.condition::TEXT AS condition,
    dp.name AS drop_point_name,
    dp.address AS drop_point_address,
    dp.city,
    dp.latitude,
    dp.longitude,
    u.username AS registered_by
FROM book_copies bc
JOIN books b ON bc.book_id = b.id
JOIN users u ON bc.registered_by = u.id
LEFT JOIN book_authors ba ON b.id = ba.book_id
LEFT JOIN authors a ON ba.author_id = a.id
LEFT JOIN book_genres bg ON b.id = bg.book_id
LEFT JOIN genres g ON bg.genre_id = g.id
LEFT JOIN LATERAL (
    SELECT drop_point_id FROM transfers
    WHERE copy_id = bc.id ORDER BY id DESC LIMIT 1
) t ON TRUE
LEFT JOIN drop_points dp ON t.drop_point_id = dp.id
WHERE bc.status = 'available'
GROUP BY bc.id, bc.unique_code, b.title, b.published_year,
    bc.condition, dp.name, dp.address, dp.city,
    dp.latitude, dp.longitude, u.username;

CREATE OR REPLACE VIEW v_user_activity AS
SELECT
    u.id,
    u.username,
    u.city,
    u.rating,
    u.registered_at,
    COUNT(DISTINCT bc.id) AS copies_registered,
    COUNT(DISTINCT t_out.id) AS copies_given,
    COUNT(DISTINCT t_in.id) AS copies_received,
    COUNT(DISTINCT r.id) AS reviews_written,
    COALESCE(
        GREATEST(MAX(t_out.transfer_date), MAX(t_in.transfer_date)),
        u.registered_at
    ) AS last_active_at
FROM users u
LEFT JOIN book_copies bc ON bc.registered_by = u.id
LEFT JOIN transfers t_out ON t_out.from_user_id = u.id
LEFT JOIN transfers t_in ON t_in.to_user_id = u.id
LEFT JOIN reviews r ON r.user_id = u.id
GROUP BY u.id, u.username, u.city, u.rating, u.registered_at;

CREATE OR REPLACE FUNCTION fn_user_rating(p_user_id INTEGER)
RETURNS NUMERIC(3,2) LANGUAGE plpgsql AS $$
DECLARE
    v_transfer_count INTEGER;
    v_review_score NUMERIC(5,4);
    v_condition_score NUMERIC(5,4);
    v_timeliness_score NUMERIC(5,4);
    v_activity_score NUMERIC(5,4);
    v_avg_cond_delta NUMERIC(5,4);
    v_avg_days_held NUMERIC(8,2);
BEGIN
    SELECT COUNT(*) INTO v_transfer_count
    FROM transfers WHERE from_user_id = p_user_id;
    IF v_transfer_count = 0 THEN
        RETURN 5.00;
    END IF;

    SELECT COALESCE(AVG(r.rating), 5.0) INTO v_review_score
    FROM reviews r
    JOIN book_copies bc ON r.copy_id = bc.id
    WHERE bc.registered_by = p_user_id;

    WITH cond_pairs AS (
        SELECT
            ARRAY_POSITION(ARRAY['poor','fair','good','new']::TEXT[], t_out.condition_at_transfer::TEXT)
            - ARRAY_POSITION(ARRAY['poor','fair','good','new']::TEXT[], t_prev.condition_at_transfer::TEXT) AS delta
        FROM transfers t_out
        JOIN LATERAL (
            SELECT condition_at_transfer, to_user_id FROM transfers
            WHERE copy_id = t_out.copy_id AND id < t_out.id
            ORDER BY id DESC LIMIT 1
        ) t_prev ON TRUE
        WHERE t_out.from_user_id = p_user_id
          AND t_prev.to_user_id = p_user_id
          AND t_out.condition_at_transfer IS NOT NULL
          AND t_prev.condition_at_transfer IS NOT NULL
    )
    SELECT AVG(delta) INTO v_avg_cond_delta FROM cond_pairs;

    v_condition_score := CASE
        WHEN v_avg_cond_delta IS NULL THEN 4.0
        WHEN v_avg_cond_delta >= 0 THEN 5.0
        WHEN v_avg_cond_delta >= -0.5 THEN 3.5
        WHEN v_avg_cond_delta >= -1.0 THEN 2.0
        ELSE 0.5
    END;

    WITH hold_dur AS (
        SELECT DATE_PART('day', t_out.transfer_date - t_prev.transfer_date) AS days
        FROM transfers t_out
        JOIN LATERAL (
            SELECT transfer_date, to_user_id FROM transfers
            WHERE copy_id = t_out.copy_id AND id < t_out.id
            ORDER BY id DESC LIMIT 1
        ) t_prev ON TRUE
        WHERE t_out.from_user_id = p_user_id
          AND t_prev.to_user_id = p_user_id
    )
    SELECT AVG(days) INTO v_avg_days_held FROM hold_dur;

    v_timeliness_score := CASE
        WHEN v_avg_days_held IS NULL THEN 4.0
        WHEN v_avg_days_held <= 30 THEN 5.0
        WHEN v_avg_days_held <= 60 THEN 4.0
        WHEN v_avg_days_held <= 90 THEN 3.0
        WHEN v_avg_days_held <= 120 THEN 2.0
        ELSE 1.0
    END;

    v_activity_score := LEAST(v_transfer_count::NUMERIC / 20.0 * 5.0, 5.0);

    RETURN GREATEST(1.00, LEAST(5.00,
        ROUND(v_review_score * 0.40 + v_condition_score * 0.25
            + v_timeliness_score * 0.20 + v_activity_score * 0.15, 2)
    ));
END;
$$;

CREATE OR REPLACE FUNCTION fn_book_journey(p_unique_code VARCHAR(20))
RETURNS TABLE (
    step_number INTEGER,
    transfer_date TIMESTAMP,
    from_user VARCHAR(50),
    to_user VARCHAR(50),
    condition TEXT,
    drop_point VARCHAR(200),
    city VARCHAR(100),
    days_in_hands INTEGER
) LANGUAGE sql STABLE AS $$
SELECT
    ROW_NUMBER() OVER (ORDER BY t.transfer_date, t.id)::INTEGER,
    t.transfer_date,
    COALESCE(uf.username, '— первичная регистрация —'),
    ut.username,
    COALESCE(t.condition_at_transfer::TEXT, '—'),
    COALESCE(dp.name, 'прямая передача'),
    dp.city,
    COALESCE(DATE_PART('day',
        t.transfer_date - LAG(t.transfer_date) OVER (ORDER BY t.transfer_date, t.id)
    )::INTEGER, 0)
FROM transfers t
JOIN book_copies bc ON t.copy_id = bc.id
LEFT JOIN users uf ON t.from_user_id = uf.id
JOIN users ut ON t.to_user_id = ut.id
LEFT JOIN drop_points dp ON t.drop_point_id = dp.id
WHERE bc.unique_code = p_unique_code
ORDER BY t.transfer_date, t.id;
$$;

CREATE OR REPLACE FUNCTION fn_can_user_participate(p_user_id INTEGER)
RETURNS TABLE (
    can_receive BOOLEAN,
    can_register BOOLEAN,
    account_status TEXT,
    reason TEXT
) LANGUAGE plpgsql AS $$
DECLARE
    v_rating NUMERIC(3,2);
    v_username VARCHAR(50);
BEGIN
    SELECT rating, username INTO v_rating, v_username
    FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Пользователь с ID % не найден', p_user_id;
    END IF;

    IF v_rating >= 4.0 THEN
        RETURN QUERY SELECT TRUE, TRUE, 'trusted'::TEXT,
            FORMAT('Рейтинг %s — доверенный участник', v_rating);
    ELSIF v_rating >= 3.0 THEN
        RETURN QUERY SELECT TRUE, TRUE, 'standard'::TEXT,
            FORMAT('Рейтинг %s — стандартный участник', v_rating);
    ELSIF v_rating >= 2.0 THEN
        RETURN QUERY SELECT FALSE, TRUE, 'restricted'::TEXT,
            FORMAT('Рейтинг %s — только регистрация книг', v_rating);
    ELSE
        RETURN QUERY SELECT FALSE, FALSE, 'suspended'::TEXT,
            FORMAT('Рейтинг %s — аккаунт заблокирован', v_rating);
    END IF;
END;
$$;

CREATE OR REPLACE VIEW v_user_reputation AS
WITH cond_analytics AS (
    SELECT
        t_out.from_user_id AS user_id,
        t_out.id AS transfer_id,
        ARRAY_POSITION(ARRAY['poor','fair','good','new']::TEXT[], t_out.condition_at_transfer::TEXT)
        - ARRAY_POSITION(ARRAY['poor','fair','good','new']::TEXT[], t_prev.condition_at_transfer::TEXT) AS cond_delta
    FROM transfers t_out
    JOIN LATERAL (
        SELECT condition_at_transfer, to_user_id FROM transfers
        WHERE copy_id = t_out.copy_id AND id < t_out.id
        ORDER BY id DESC LIMIT 1
    ) t_prev ON t_prev.to_user_id = t_out.from_user_id
    WHERE t_out.condition_at_transfer IS NOT NULL
      AND t_prev.condition_at_transfer IS NOT NULL
),
hold_analytics AS (
    SELECT
        t_out.from_user_id AS user_id,
        t_out.id AS transfer_id,
        DATE_PART('day', t_out.transfer_date - t_prev.transfer_date) AS days_held
    FROM transfers t_out
    JOIN LATERAL (
        SELECT transfer_date, to_user_id FROM transfers
        WHERE copy_id = t_out.copy_id AND id < t_out.id
        ORDER BY id DESC LIMIT 1
    ) t_prev ON t_prev.to_user_id = t_out.from_user_id
),
ca_agg AS (
    SELECT user_id,
        ROUND(AVG(cond_delta), 2) AS avg_cond_change,
        COUNT(CASE WHEN cond_delta < 0 THEN 1 END) AS books_damaged
    FROM cond_analytics GROUP BY user_id
),
ha_agg AS (
    SELECT user_id,
        ROUND(AVG(days_held)::NUMERIC, 0)::INTEGER AS avg_days_held,
        COUNT(CASE WHEN days_held > 90 THEN 1 END) AS overdue_count
    FROM hold_analytics GROUP BY user_id
)
SELECT
    u.id, u.username, u.city, u.rating,
    COUNT(DISTINCT t_out.id) AS books_given,
    COUNT(DISTINCT t_in.id) AS books_received,
    COUNT(DISTINCT bc.id) AS books_registered,
    ca.avg_cond_change,
    ca.books_damaged,
    ha.avg_days_held,
    ha.overdue_count,
    CASE
        WHEN u.rating >= 4.0 THEN 'trusted'
        WHEN u.rating >= 3.0 THEN 'standard'
        WHEN u.rating >= 2.0 THEN 'restricted'
        ELSE 'suspended'
    END AS account_status
FROM users u
LEFT JOIN book_copies bc ON bc.registered_by = u.id
LEFT JOIN transfers t_out ON t_out.from_user_id = u.id
LEFT JOIN transfers t_in ON t_in.to_user_id = u.id
LEFT JOIN ca_agg ca ON ca.user_id = u.id
LEFT JOIN ha_agg ha ON ha.user_id = u.id
GROUP BY u.id, u.username, u.city, u.rating,
    ca.avg_cond_change, ca.books_damaged, ha.avg_days_held, ha.overdue_count;

CREATE OR REPLACE FUNCTION trg_fn_before_transfer_insert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.condition_at_transfer IS NULL THEN
        SELECT condition INTO NEW.condition_at_transfer
        FROM book_copies WHERE id = NEW.copy_id;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_before_transfer_insert ON transfers;
CREATE TRIGGER trg_before_transfer_insert
BEFORE INSERT ON transfers FOR EACH ROW
EXECUTE FUNCTION trg_fn_before_transfer_insert();

CREATE OR REPLACE FUNCTION trg_fn_after_transfer()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_current_holder INTEGER;
    v_status copy_status;
BEGIN
    SELECT current_holder, status INTO v_current_holder, v_status
    FROM book_copies WHERE id = NEW.copy_id;

    IF v_status = 'available' THEN
        IF NEW.from_user_id IS NOT NULL THEN
            RAISE EXCEPTION 'Книга свободна, нельзя указать отправителя';
        END IF;
    ELSE
        IF v_current_holder IS DISTINCT FROM NEW.from_user_id THEN
            RAISE EXCEPTION 'Отправитель (ID=%) не является текущим держателем', NEW.from_user_id;
        END IF;
    END IF;

    UPDATE book_copies
    SET current_holder = NEW.to_user_id,
        status = 'taken',
        condition = COALESCE(NEW.condition_at_transfer, condition)
    WHERE id = NEW.copy_id;

    IF NEW.from_user_id IS NOT NULL THEN
        UPDATE users SET rating = fn_user_rating(NEW.from_user_id)
        WHERE id = NEW.from_user_id;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_after_transfer_insert ON transfers;
CREATE TRIGGER trg_after_transfer_insert
AFTER INSERT ON transfers FOR EACH ROW
EXECUTE FUNCTION trg_fn_after_transfer();

CREATE OR REPLACE FUNCTION trg_fn_after_review_insert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_registered_by INTEGER;
BEGIN
    SELECT registered_by INTO v_registered_by
    FROM book_copies WHERE id = NEW.copy_id;
    UPDATE users SET rating = fn_user_rating(v_registered_by)
    WHERE id = v_registered_by;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_after_review_insert ON reviews;
CREATE TRIGGER trg_after_review_insert
AFTER INSERT ON reviews FOR EACH ROW
EXECUTE FUNCTION trg_fn_after_review_insert();

CREATE OR REPLACE FUNCTION trg_fn_log_status_change()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO copy_status_log (copy_id, old_status, new_status)
    VALUES (NEW.id, OLD.status, NEW.status);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_log_status_change ON book_copies;
CREATE TRIGGER trg_log_status_change
AFTER UPDATE OF status ON book_copies FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_log_status_change();

CREATE OR REPLACE PROCEDURE sp_transfer_book(
    p_copy_id INTEGER,
    p_from_user_id INTEGER,
    p_to_user_id INTEGER,
    p_drop_point_id INTEGER DEFAULT NULL,
    p_note TEXT DEFAULT NULL,
    p_condition_at_handoff copy_condition DEFAULT NULL
) LANGUAGE plpgsql AS $$
DECLARE
    v_status copy_status;
    v_book_title VARCHAR(255);
    v_can_receive BOOLEAN;
    v_reason TEXT;
    v_is_active BOOLEAN;
BEGIN
    IF p_drop_point_id IS NOT NULL THEN
        SELECT is_active INTO v_is_active
        FROM drop_points WHERE id = p_drop_point_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Точка обмена с ID % не найдена', p_drop_point_id;
        END IF;
        IF NOT v_is_active THEN
            RAISE EXCEPTION 'Точка обмена ID % неактивна', p_drop_point_id;
        END IF;
    END IF;

    SELECT bc.status, b.title INTO v_status, v_book_title
    FROM book_copies bc
    JOIN books b ON bc.book_id = b.id
    WHERE bc.id = p_copy_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Экземпляр с ID % не найден', p_copy_id;
    END IF;

    IF v_status = 'lost' THEN
        RAISE EXCEPTION 'Экземпляр "%" помечен как утерянный', v_book_title;
    END IF;

    IF p_from_user_id = p_to_user_id THEN
        RAISE EXCEPTION 'Отправитель и получатель не могут совпадать';
    END IF;

    SELECT t.can_receive, t.reason INTO v_can_receive, v_reason
    FROM fn_can_user_participate(p_to_user_id) t;

    IF NOT v_can_receive THEN
        RAISE EXCEPTION 'Получатель не может брать книги. %', v_reason;
    END IF;

    INSERT INTO transfers
        (copy_id, from_user_id, to_user_id, drop_point_id, note, condition_at_transfer)
    VALUES
        (p_copy_id, p_from_user_id, p_to_user_id, p_drop_point_id, p_note, p_condition_at_handoff);

    RAISE NOTICE 'Книга "%" передана пользователю ID %', v_book_title, p_to_user_id;
EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'Несуществующий пользователь или точка обмена';
    WHEN check_violation THEN
        RAISE EXCEPTION 'Нарушение ограничения данных';
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Ошибка при передаче (copy_id=%)', p_copy_id;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_mark_copy_lost(
    p_copy_id INTEGER,
    p_reported_by INTEGER,
    p_reason TEXT DEFAULT NULL
) LANGUAGE plpgsql AS $$
DECLARE
    v_status copy_status;
    v_book_title VARCHAR(255);
    v_unique_code VARCHAR(20);
    v_current_holder INTEGER;
BEGIN
    SELECT bc.status, b.title, bc.unique_code, bc.current_holder
    INTO v_status, v_book_title, v_unique_code, v_current_holder
    FROM book_copies bc
    JOIN books b ON bc.book_id = b.id
    WHERE bc.id = p_copy_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Экземпляр с ID % не найден', p_copy_id;
    END IF;

    IF v_status = 'lost' THEN
        RAISE EXCEPTION 'Экземпляр "%" (%) уже помечен как утерянный',
            v_book_title, v_unique_code;
    END IF;

    IF v_current_holder IS NOT NULL AND v_current_holder != p_reported_by THEN
        IF NOT (pg_has_role(current_user, 'bc_admin', 'MEMBER')
             OR pg_has_role(current_user, 'bc_moderator', 'MEMBER')) THEN
            RAISE EXCEPTION 'Только текущий держатель или модератор может пометить книгу как утерянную';
        END IF;
    END IF;

    UPDATE book_copies
    SET status = 'lost', current_holder = NULL
    WHERE id = p_copy_id;

    RAISE NOTICE 'Экземпляр "%" (%) -> lost. Причина: %. Сообщил: ID %',
        v_book_title, v_unique_code, COALESCE(p_reason, 'не указана'), p_reported_by;
EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Ошибка при изменении статуса';
END;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO bc_admin, bc_moderator;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA public TO bc_admin, bc_moderator;
GRANT EXECUTE ON FUNCTION fn_user_rating(INTEGER) TO bc_user;
GRANT EXECUTE ON FUNCTION fn_book_journey(VARCHAR) TO bc_user;
GRANT EXECUTE ON FUNCTION fn_can_user_participate(INTEGER) TO bc_user;