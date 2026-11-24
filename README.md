## Запуск

cp .env.example .env

sudo docker compose up -d --build

Порт и приветствие настраиваются в `.env` через `HOST_PORT` и `GREETING`
остановка: `sudo docker compose down`

## Проверки

### Счётчик

curl http://localhost:8080/

curl -X POST http://localhost:8080/increment

После 3 POST-запросов счётчик стал 3
После `docker compose down` и повторного запуска значение сохранилось благодаря volume

### Redis

sudo docker compose stop redis

curl -i http://localhost:8080/healthz

curl -i http://localhost:8080/readyz

curl -i -X POST http://localhost:8080/increment

Получены коды 200, 503, 503
После `sudo docker compose start redis` счётчик сохранился, приложение продолжило работу без перезапуска

### Ограничения

UID=67, read_only=true, память 256 MiB, CPU 1

### Скрипт проверки

./scripts/check.sh



Два успешных запуска подряд было проведено
Скрипт проверяет счётчик, пересоздание app, отключение и восстановление Redis, создаёт резервную копию и удаляет тестовые ресурсы
