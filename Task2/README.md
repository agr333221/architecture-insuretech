# Задание 2. Динамическое масштабирование

Стенд: minikube v1.38.1 (драйвер docker, Kubernetes v1.35.1, 4 CPU, 6 GB), аддоны metrics-server и dashboard, kube-prometheus-stack + prometheus-adapter (helm), нагрузка - locust 2.46 (`locustfile.py` из задания) через `minikube service scaletestapp --url`.

## Структура

| Путь | Содержимое |
|---|---|
| `part1/deployment.yaml` | Deployment: 1 реплика, limit memory 30Mi, request memory 15Mi |
| `part1/service.yaml` | Service (NodePort 30080 -> 8080) |
| `part1/hpa-memory.yaml` | HPA по памяти: 80%, 1..10 реплик |
| `part2/kube-prometheus-stack-values.yaml` | values для установки Prometheus |
| `part2/servicemonitor.yaml` | экспорт `/metrics` приложения в Prometheus |
| `part2/prometheus-adapter-values.yaml` | `http_requests_total` -> `http_requests_per_second` (Custom Metrics API) |
| `part2/hpa-rps.yaml` | HPA по RPS: 5 запросов/с на под, 1..10 реплик |
| `locustfile.py` | сценарий нагрузки из задания |
| `logs/` | логи прогона |
| `screenshots/` | скриншоты Kubernetes Dashboard и Prometheus |

## Часть 1. HPA по памяти

Нагрузка: 300 пользователей, 10 минут. Итог locust: 48 315 запросов, 0 ошибок, ~81 RPS (`logs/part1-locust_stats.csv`, `logs/part1-locust-report.html`).

| Время | Утилизация памяти (от request) | Реплик |
|---|---|---|
| до нагрузки | 45% | 1 |
| ~7 мин нагрузки | 90% (> 80% + допуск 10%) | 1 -> **2** |
| после масштабирования | 67-71% | 2 |

Событие HPA (`logs/part1-hpa-describe.log`, `logs/part1-events.log`):

```
SuccessfulRescale  New size: 2; reason: memory resource utilization (percentage of request) above target
ScalingReplicaSet  Scaled up replica set scaletestapp-6dd75f784f from 1 to 2
```

Скриншоты:

| Файл | Что видно |
|---|---|
| `part1-01-before-workloads.png` | до нагрузки: 1 под |
| `part1-02-load-workloads.png`, `part1-03-load-workloads.png` | во время нагрузки |
| `part1-04-load-end-workloads.png` | конец нагрузки: Deployment 2/2, 2 пода |
| `part1-05-after-workloads.png` | после нагрузки |
| `part1-05-after-deployment-hpa.png` | страница Deployment: HPA и событие "New size: 2; reason: memory resource utilization ... above target" |

Полная динамика с шагом 10 с - `logs/part1-hpa-watch.log` (`kubectl get hpa`, `kubectl top pods`, `kubectl get deploy`).

### Почему request памяти 15Mi, а не 30Mi

HPA считает утилизацию памяти от `requests`, а не от `limits`, и не масштабирует, пока отклонение от цели меньше 10% (tolerance).

- При `requests = limits = 30Mi` реплики добавляются только с ~26,4Mi (88% от 30Mi), почти у лимита. Под убивается по OOM раньше, чем HPA успевает сработать: это ровно проблема из условия задания. На практике при 300-1000 пользователях память держалась на 70-83% от 30Mi, и масштабирования не было.
- При `requests = 15Mi` порог около 13,2Mi. В покое под занимает 5-7Mi (33-47%), под нагрузкой около 16Mi, и HPA добавляет реплики до достижения лимита 30Mi.

Лимит памяти 30Mi оставлен, как требует задание.

## Часть 2. HPA по RPS (Prometheus)

1. Prometheus установлен через `kube-prometheus-stack` (`logs/04-install-prometheus.log`).
2. Метрики приложения экспортируются через `ServiceMonitor`. Target `serviceMonitor/default/scaletestapp/0` в состоянии UP (`screenshots/part2-prometheus-01-targets.png`, `logs/part2-prometheus-targets.log`).
3. Метрика `http_requests_total` видна в Prometheus (`part2-prometheus-02-http_requests_total-table.png`, `part2-prometheus-03-http_requests_total-graph.png`).
4. prometheus-adapter публикует `http_requests_per_second` в Custom Metrics API (`logs/05-install-prometheus-adapter.log`, `logs/part2-custom-metrics.log`).
5. HPA `part2/hpa-rps.yaml` заменяет HPA по памяти (`logs/06-apply-hpa-rps.log`).

Нагрузка: 300 пользователей, 8 минут. Итог locust: 38 377 запросов, 0 ошибок, ~80 RPS.

| Время | RPS на под (среднее) | Реплик |
|---|---|---|
| до нагрузки | 0 | 1 |
| начало нагрузки | 5,5 -> 26,9 -> 54,2 -> 76,3 | 1 -> 2 -> 6 -> **10** |
| нагрузка, 10 реплик | ~8 (80 RPS / 10 подов) | 10 (максимум) |
| после нагрузки | 0 | 10 -> 2 -> **1** |

События HPA (`logs/part2-hpa-describe.log`):

```
SuccessfulRescale  New size: 2;  reason: pods metric http_requests_per_second above target
SuccessfulRescale  New size: 6;  reason: pods metric http_requests_per_second above target
SuccessfulRescale  New size: 10; reason: pods metric http_requests_per_second above target
SuccessfulRescale  New size: 2;  reason: All metrics below target
SuccessfulRescale  New size: 1;  reason: All metrics below target
```

Скриншоты:

| Файл | Что видно |
|---|---|
| `part2-prometheus-01-targets.png` | Prometheus -> Target health: scaletestapp UP |
| `part2-prometheus-02-http_requests_total-table.png` | значение `http_requests_total` |
| `part2-prometheus-03-http_requests_total-graph.png` | рост счетчика за 30 минут |
| `part2-prometheus-04-rps-by-pod-*.png` | `sum by (pod) (rate(http_requests_total[1m]))` во время нагрузки |
| `part2-01-before-*.png` | до нагрузки: 1 под |
| `part2-02-load-*.png`, `part2-03-load-*.png`, `part2-04-load-end-*.png` | нагрузка: Deployment 10/10 |
| `part2-05-after-*.png` | после нагрузки: обратное масштабирование до 1, события HPA на странице Deployment |

Время на графиках Prometheus указано в UTC (23:58 UTC = 02:58 MSK).

## Особенности стенда

- **Распределение трафика.** На Windows с драйвером docker `minikube service --url` работает через SSH-туннель. Locust держит keep-alive соединения, а kube-proxy балансирует соединения, а не запросы, поэтому основная часть трафика идет в поды, существовавшие в момент открытия соединений (это видно на графике RPS по подам). На решение HPA это не влияет: он считает среднее значение метрики на под. В продуктивной среде с Ingress/L7-балансировщиком нагрузка распределяется по всем репликам.
- **Предел туннеля.** SSH-туннель не выдерживает 1000 одновременных пользователей (до 59% ошибок соединения), поэтому нагрузка ограничена 300 пользователями (~80 RPS, 0 ошибок).
- **readinessProbe** обращается к `/metrics`, а не к `/`. Запросы к `/` увеличивают `http_requests_total`, и проба искажала бы метрику, по которой работает HPA части 2.

## Как воспроизвести

```
minikube start --driver=docker --cpus=4 --memory=6144mb
minikube addons enable metrics-server
minikube addons enable dashboard
kubectl apply -f part1/deployment.yaml -f part1/service.yaml -f part1/hpa-memory.yaml
minikube service scaletestapp --url
locust -f locustfile.py --headless -u 300 -r 10 -t 10m --host <url>
kubectl get hpa -w

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus-operator prometheus-community/kube-prometheus-stack -n monitoring --create-namespace -f part2/kube-prometheus-stack-values.yaml
kubectl apply -f part2/servicemonitor.yaml
helm install prometheus-adapter prometheus-community/prometheus-adapter -n monitoring -f part2/prometheus-adapter-values.yaml
kubectl delete hpa scaletestapp
kubectl apply -f part2/hpa-rps.yaml
kubectl -n monitoring port-forward svc/prometheus-operator-kube-p-prometheus 9090:9090
locust -f locustfile.py --headless -u 300 -r 10 -t 8m --host <url>
```

Скрипт `scripts/run-task2.ps1` автоматизирует те же шаги для Windows.
