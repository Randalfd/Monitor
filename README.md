# Monitor Script

Script de monitoreo de recursos del sistema.

## Dependencias

- sendmail para el modulo de mails
- gettext para el modulo de la plantilla html

## Features Implementadas

### 1. Registro de datos (CPU, Mem, Swap, Disk)

El bucle principal captura cada `INTERVAL` segundos los valores de:

- **CPU**: uso actual en porcentaje (`user + system`)
- **Mem**: porcentaje de memoria usada
- **Swap**: porcentaje de swap usado
- **Disk**: porcentaje usado de `/`

Los valores se almacenan en el `status_dto` (contrato estable de intercambio de información) y se imprimen en cada iteración.

### 2. Estadísticas finales

Al terminar el tiempo configurado, se calculan y muestran usando el `table_dto`:

- **CPU / Mem / Swap**: Mínimo, Máximo y Promedio (media de todas las capturas)
- **Disk**: Último valor capturado

El `table_dto` define el contrato de salida para integración con páginas (Dashboard).

### 3. DTOs (Contratos de datos)

- `status_dto`: `timestamp`, `cpu`, `ram`, `swap`, `disk` — métricas de cada iteración
- `table_dto`: `timestamp`, `minCpu`, `minRam`, `minSwap`, `minDisk`, `lastDisk`, `avgCpu`, `avgRam`, `avgSwap`, `maxCpu`, `maxRam`, `maxSwap`, `maxDisk` — estadísticas agregadas

### 4. Alertas

El script emite alertas cuando detecta condiciones de insuficiencia de recursos:

- **CPU**: si en 3 ciclos consecutivos se detecta un consumo > 80%, alerta y envía mail al correo del administrador (envío real vía `sendmail -t`, destinatario de prueba).
- **Disco**: si el espacio restante es < 15%, alerta y pregunta al usuario si desea eliminar archivos temporales.
- **RAM**: si el RAM < 10%, alerta y lista los 5 procesos de alto consumo de RAM.

> El mail de alerta solo se envía para alertas de CPU.

Formato de cada alerta:

```
Warning: <problema>
Date: timestamp
```

## Uso

```bash
bash scripts/monitor.sh
# Introducir tiempo limite(minutos): <valor en minutos>
# Espera a que finalice el tiempo y muestra estadísticas
```
