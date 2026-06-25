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