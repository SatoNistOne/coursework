DROP TABLE IF EXISTS copy_status_log CASCADE;
DROP TABLE IF EXISTS reviews CASCADE;
DROP TABLE IF EXISTS transfers CASCADE;
DROP TABLE IF EXISTS book_copies CASCADE;
DROP TABLE IF EXISTS drop_points CASCADE;
DROP TABLE IF EXISTS book_genres CASCADE;
DROP TABLE IF EXISTS book_authors CASCADE;
DROP TABLE IF EXISTS genres CASCADE;
DROP TABLE IF EXISTS books CASCADE;
DROP TABLE IF EXISTS authors CASCADE;
DROP TABLE IF EXISTS users CASCADE;
DROP TYPE IF EXISTS copy_status CASCADE;
DROP TYPE IF EXISTS copy_condition CASCADE;

CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) NOT NULL UNIQUE,
    email VARCHAR(100) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    city VARCHAR(100),
    rating NUMERIC(3,2) NOT NULL DEFAULT 5.00 CHECK (rating BETWEEN 0.00 AND 5.00),
    registered_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE books (
    id SERIAL PRIMARY KEY,
    title VARCHAR(255) NOT NULL,
    isbn VARCHAR(20) UNIQUE,
    published_year SMALLINT CHECK (published_year BETWEEN 1 AND 2100),
    description TEXT
);

CREATE TABLE authors (
    id SERIAL PRIMARY KEY,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL
);

CREATE TABLE book_authors (
    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    author_id INTEGER NOT NULL REFERENCES authors(id) ON DELETE CASCADE,
    PRIMARY KEY (book_id, author_id)
);

CREATE TABLE genres (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE book_genres (
    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    genre_id INTEGER NOT NULL REFERENCES genres(id) ON DELETE CASCADE,
    PRIMARY KEY (book_id, genre_id)
);

CREATE TYPE copy_status AS ENUM ('available', 'taken', 'lost');
CREATE TYPE copy_condition AS ENUM ('new', 'good', 'fair', 'poor');

CREATE TABLE book_copies (
    id SERIAL PRIMARY KEY,
    book_id INTEGER NOT NULL REFERENCES books(id),
    registered_by INTEGER NOT NULL REFERENCES users(id),
    current_holder INTEGER REFERENCES users(id),
    status copy_status NOT NULL DEFAULT 'available',
    condition copy_condition NOT NULL DEFAULT 'good',
    unique_code VARCHAR(20) NOT NULL UNIQUE,
    registered_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE drop_points (
    id SERIAL PRIMARY KEY,
    name VARCHAR(200) NOT NULL,
    address VARCHAR(300) NOT NULL,
    city VARCHAR(100) NOT NULL,
    latitude NUMERIC(9,6),
    longitude NUMERIC(9,6),
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE transfers (
    id SERIAL PRIMARY KEY,
    copy_id INTEGER NOT NULL REFERENCES book_copies(id),
    from_user_id INTEGER REFERENCES users(id),
    to_user_id INTEGER NOT NULL REFERENCES users(id),
    drop_point_id INTEGER REFERENCES drop_points(id),
    transfer_date TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    condition_at_transfer copy_condition NOT NULL,
    note TEXT
);

CREATE TABLE reviews (
    id SERIAL PRIMARY KEY,
    copy_id INTEGER NOT NULL REFERENCES book_copies(id),
    user_id INTEGER NOT NULL REFERENCES users(id),
    rating SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (copy_id, user_id)
);

CREATE TABLE copy_status_log (
    id SERIAL PRIMARY KEY,
    copy_id INTEGER NOT NULL REFERENCES book_copies(id),
    old_status copy_status,
    new_status copy_status NOT NULL,
    db_role VARCHAR(100) NOT NULL DEFAULT current_user,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_copies_status ON book_copies(status);
CREATE INDEX idx_copies_book ON book_copies(book_id);
CREATE INDEX idx_transfers_copy ON transfers(copy_id);
CREATE INDEX idx_transfers_date ON transfers(transfer_date);
CREATE INDEX idx_droppoints_city ON drop_points(city);
CREATE INDEX idx_users_city ON users(city);
CREATE INDEX idx_log_copy ON copy_status_log(copy_id);
CREATE INDEX idx_reviews_copy ON reviews(copy_id);
CREATE INDEX idx_reviews_user ON reviews(user_id);

DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'bc_admin') THEN
        CREATE ROLE bc_admin LOGIN PASSWORD 'Admin@BookCross1';
    END IF;
END $$;

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO bc_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO bc_admin;
GRANT TRUNCATE ON transfers, reviews, copy_status_log, book_copies,
    drop_points, book_authors, book_genres, books, authors, genres, users TO bc_admin;

DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'bc_moderator') THEN
        CREATE ROLE bc_moderator LOGIN PASSWORD 'Moder@BookCross1';
    END IF;
END $$;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO bc_moderator;
GRANT INSERT, UPDATE, DELETE ON drop_points TO bc_moderator;
GRANT UPDATE ON book_copies TO bc_moderator;
GRANT DELETE ON reviews TO bc_moderator;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO bc_moderator;

DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'bc_user') THEN
        CREATE ROLE bc_user LOGIN PASSWORD 'User@BookCross1';
    END IF;
END $$;

GRANT SELECT ON books, authors, genres, book_authors, book_genres,
    book_copies, drop_points, transfers, reviews TO bc_user;
GRANT INSERT ON book_copies, transfers, reviews TO bc_user;
GRANT UPDATE (status, current_holder) ON book_copies TO bc_user;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO bc_user;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
REVOKE EXECUTE ON ALL PROCEDURES IN SCHEMA public FROM PUBLIC;

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

    SAVEPOINT before_insert;

    BEGIN
        INSERT INTO transfers
            (copy_id, from_user_id, to_user_id, drop_point_id, note, condition_at_transfer)
        VALUES
            (p_copy_id, p_from_user_id, p_to_user_id, p_drop_point_id, p_note, p_condition_at_handoff);

        RAISE NOTICE 'Книга "%" передана пользователю ID %', v_book_title, p_to_user_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK TO SAVEPOINT before_insert;
            RAISE EXCEPTION 'Ошибка при вставке передачи: %', SQLERRM;
    END;

EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'Несуществующий пользователь или точка обмена';
    WHEN check_violation THEN
        RAISE EXCEPTION 'Нарушение ограничения данных';
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Ошибка при передаче (copy_id=%): %', p_copy_id, SQLERRM;
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
        RAISE EXCEPTION 'Ошибка при изменении статуса: %', SQLERRM;
END;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO bc_admin, bc_moderator;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA public TO bc_admin, bc_moderator;
GRANT EXECUTE ON FUNCTION fn_user_rating(INTEGER) TO bc_user;
GRANT EXECUTE ON FUNCTION fn_book_journey(VARCHAR) TO bc_user;
GRANT EXECUTE ON FUNCTION fn_can_user_participate(INTEGER) TO bc_user;

INSERT INTO users (username, email, password_hash, city, rating) VALUES
('ivanov_ivan',    'ivanov@mail.ru',     'hash_1', 'Москва',          5.00),
('petrov_petr',    'petrov@mail.ru',     'hash_2', 'Санкт-Петербург', 5.00),
('sidorova_anna',  'sidorova@mail.ru',   'hash_3', 'Москва',          5.00),
('kozlov_dmitry',  'kozlov@mail.ru',     'hash_4', 'Казань',          5.00),
('smirnova_olga',  'smirnova@mail.ru',   'hash_5', 'Москва',          5.00),
('novikov_sergey', 'novikov@mail.ru',    'hash_6', 'Санкт-Петербург', 5.00);

INSERT INTO authors (first_name, last_name) VALUES
('Михаил',    'Булгаков'),
('Фёдор',     'Достоевский'),
('Лев',       'Толстой'),
('Джоан',     'Роулинг'),
('Антон',     'Чехов'),
('Борис',     'Пастернак'),
('Александр', 'Пушкин');

INSERT INTO books (title, isbn, published_year, description) VALUES
('Мастер и Маргарита',                '978-5-17-090200-1', 1967, 'Роман Булгакова, сочетающий мистику, сатиру и любовную линию'),
('Преступление и наказание',          '978-5-17-090201-2', 1866, 'Психологический роман о студенте, совершившем убийство'),
('Война и мир',                       '978-5-17-090202-3', 1869, 'Роман-эпопея о России эпохи Наполеоновских войн'),
('Гарри Поттер и философский камень', '978-5-17-090203-4', 1997, 'Первая книга серии о юном волшебнике'),
('Вишнёвый сад',                      '978-5-17-090204-5', 1904, 'Последняя пьеса Антона Чехова'),
('Доктор Живаго',                     '978-5-17-090205-6', 1957, 'Нобелевский роман Пастернака'),
('Евгений Онегин',                    '978-5-17-090206-7', 1833, 'Роман в стихах Пушкина');

INSERT INTO book_authors (book_id, author_id) VALUES
(1,1),(2,2),(3,3),(4,4),(5,5),(6,6),(7,7);

INSERT INTO genres (name) VALUES
('Роман'),('Классика'),('Фэнтези'),('Пьеса'),('Поэзия'),('Исторический');

INSERT INTO book_genres (book_id, genre_id) VALUES
(1,1),(1,2),
(2,1),(2,2),
(3,1),(3,2),(3,6),
(4,3),
(5,4),(5,2),
(6,1),(6,2),
(7,5),(7,2);

INSERT INTO drop_points (name, address, city, latitude, longitude, is_active) VALUES
('Библиотека им. Пушкина', 'ул. Пушкина, 10',     'Москва',          55.755826, 37.617299, TRUE),
('Кофейня «Читальня»',     'ул. Арбат, 25',       'Москва',          55.751244, 37.590743, TRUE),
('ТЦ Галерея',             'Лиговский пр., 30',   'Санкт-Петербург', 59.927082, 30.360010, TRUE),
('Парк Горького — стенд',  'Крымский Вал, 9',     'Москва',          55.729873, 37.601002, TRUE),
('КФУ, главный холл',      'ул. Кремлёвская, 18', 'Казань',          55.798525, 49.106396, TRUE),
('Книжный клуб «Буква»',   'Невский пр., 46',     'Санкт-Петербург', 59.932946, 30.344449, FALSE);

INSERT INTO book_copies (book_id, registered_by, current_holder, status, condition, unique_code) VALUES
(1, 1, NULL, 'available', 'good', 'BC-2024-0001'),
(2, 1, NULL, 'available', 'fair', 'BC-2024-0002'),
(3, 3, NULL, 'available', 'new',  'BC-2024-0003'),
(4, 2, NULL, 'available', 'good', 'BC-2024-0004'),
(5, 4, NULL, 'available', 'good', 'BC-2024-0005'),
(1, 5, NULL, 'available', 'poor', 'BC-2024-0006'),
(6, 6, NULL, 'available', 'good', 'BC-2024-0007'),
(7, 3, NULL, 'available', 'new',  'BC-2024-0008'),
(2, 4, 4,    'taken',     'poor', 'BC-2024-0009'),
(4, 1, NULL, 'available', 'fair', 'BC-2024-0010');

INSERT INTO transfers (copy_id, from_user_id, to_user_id, drop_point_id, transfer_date, note, condition_at_transfer) VALUES
(3,  NULL, 3, 1, '2024-09-20 10:00', 'Первичный выпуск в оборот', 'new'),
(2,  1, 2, 1, '2024-10-01 10:00', 'Первая передача через библиотеку', 'fair'),
(7,  6, 3, 3, '2024-10-15 12:30', 'Передача через ТЦ Галерея в СПб',  'good'),
(10, 1, 5, 2, '2024-11-01 09:00', 'Оставил у кофейни на Арбате',  'fair'),
(2,  2, 4, 2, '2024-11-10 15:00', 'Передача через Арбат',         'fair'),
(1,  1, 3, 4, '2024-11-15 14:00', 'Встреча в Парке Горького',     'good'),
(7,  3, 5, 2, '2024-11-20 11:00', 'Передача через кофейню',       'good'),
(4,  2, 4, 3, '2024-12-01 12:00', 'Через ТЦ Галерея',             'good'),
(3,  3, 1, 1, '2024-12-01 14:00', 'Через библиотеку',             'new'),
(1,  3, 5, 2, '2024-12-05 10:00', 'Кофейня на Арбате',            'good'),
(6,  5, 1, NULL, '2024-12-10 18:00', 'Прямая передача при встрече', 'poor'),
(2,  4, 3, 4, '2024-12-15 13:00', 'Парк Горького',                'poor'),
(8,  3, 2, 3, '2024-12-15 15:00', 'Через ТЦ Галерея в СПб',       'new'),
(1,  5, 2, 1, '2024-12-28 11:00', 'Через библиотеку',             'fair'),
(3,  1, 5, 4, '2025-01-05 10:00', 'Через Парк Горького',          'good'),
(4,  4, 6, 5, '2025-01-05 12:00', 'Через КФУ в Казани',           'good'),
(7,  5, 2, 1, '2025-01-08 09:30', 'Через библиотеку',             'good'),
(10, 5, 6, 5, '2025-01-12 14:00', 'Через холл КФУ',               'fair'),
(1,  2, 6, 3, '2025-01-15 16:00', 'ТЦ Галерея, финальный шаг',    'fair'),
(6,  1, 4, 4, '2025-01-30 10:00', 'Парк Горького',                'poor'),
(4,  6, 3, 1, '2025-02-02 11:00', 'Через библиотеку — вернулась в Москву', 'good'),
(8,  2, 1, 2, '2025-02-05 13:00', 'Кофейня на Арбате',            'good');

INSERT INTO reviews (copy_id, user_id, rating, comment, created_at) VALUES
(2,  2, 5, 'Отличное состояние, очень рад!',                    '2024-10-05'),
(7,  3, 4, 'Немного потрёпана, но читается хорошо',             '2024-10-20'),
(10, 5, 5, 'Давно искал — спасибо!',                            '2024-11-03'),
(2,  4, 4, 'Пара закладок от предыдущего читателя — приятно',   '2024-11-14'),
(1,  3, 5, 'Прекрасный экземпляр, рекомендую',                  '2024-11-18'),
(7,  5, 3, 'Страниц не хватает в конце, но читаемо',            '2024-11-23'),
(4,  4, 5, 'Как новая, спасибо за аккуратность!',               '2024-12-04'),
(3,  1, 5, 'Шикарное издание с иллюстрациями',                  '2024-12-04'),
(1,  5, 4, 'Хорошее состояние для такой книги',                 '2024-12-08'),
(2,  3, 4, 'Немного потёртая обложка, всё остальное идеально',  '2024-12-18'),
(8,  2, 5, 'Никогда не читал — рад что нашёл здесь',            '2024-12-18'),
(1,  2, 5, 'Завидую следующему читателю :)',                     '2024-12-30');
