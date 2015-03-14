CREATE TABLE file  (fileId              INTEGER AUTOINCREMENT,
                    path                TEXT,
                    imageId             INTEGER,
                    size                INTEGER,
                    time                INTEGER,
                    PRIMARY KEY         (fileId)
                   );
CREATE TABLE image (imageId             INTEGER AUTOINCREMENT,
                    digest              TEXT,
                    type                INTEGER,
                    compressedSize      INTEGER,
                    PRIMARY KEY         (imageId)
                   );
CREATE TABLE process_queue (
                    path                TEXT,
                    PRIMARY KEY         (path)
                   );
CREATE TABLE search_dir (
                    path                TEXT,
                    priority            INTEGER,
                    PRIMARY KEY         (path)
                   );
CREATE TABLE tag   (fileId              INTEGER,
                    key                 TEXT,
                    value               NONE,
                    PRIMARY KEY         (fileId, key)
                   );
CREATE TABLE type  (typeId              INTEGER,
                    type                TEXT,
                    PRIMARY KEY         (typeId)
                   );
CREATE        INDEX indx_tag_fileId     ON tag   (fileId);
CREATE        INDEX indx_tag_key        ON tag   (key);
CREATE        INDEX uniq_file_imageId   ON file  (imageId);
CREATE UNIQUE INDEX uniq_file_path      ON file  (path);
CREATE UNIQUE INDEX uniq_image_digest   ON image (digest);
