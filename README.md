# HDT5 — Orquestación Multiagente (Parachute S.A.)

Sistema Multiagente (MAS) para atención al cliente, evaluación meteorológica y calendarización de saltos en paracaídas para el evento nacional Guatemala 2026.

Implementa **tres arquitecturas de orquestación** sobre una capa compartida de dominio e integraciones:
1. **Centralizada**: Un orquestador principal que delega en especialistas mediante `as_tool()`.
2. **Jerárquica**: Un orquestador raíz que coordina supervisores de dominio (`Conocimiento` y `Operaciones`), los cuales a su vez coordinan agentes hoja.
3. **Descentralizada**: Red de agentes pares que se transfieren el control entre sí mediante `handoff()`, preservando contexto sin un coordinador central.

---

## 1. Arquitecturas de Orquestación

### Arquitectura 1: Centralizada (`arch_centralizada.py`)

Un único agente orquestador atiende al usuario y coordina a los especialistas como herramientas (`as_tool()`). El control siempre retorna al centro antes de emitir una respuesta consolidada.

```mermaid
graph TD
    U["Usuario"] <--> O["Orquestador Central<br/>(Único punto de contacto)"]
    
    O -->|as_tool: consultar_faqs| A1["Especialista FAQs<br/>(Conocimiento institucional)"]
    O -->|as_tool: consultar_clima_seguridad| A2["Especialista Clima/Seguridad<br/>(Pronóstico y Veredicto)"]
    O -->|as_tool: gestionar_agenda| A3["Especialista Agenda<br/>(Cupos y Citas)"]

    A1 --> T1[("PostgreSQL + pgvector<br/>120 FAQs / HNSW")]
    A2 --> T2["API Open-Meteo<br/>(Ventana 08-16h)"]
    A2 --> T3["core/safety.py<br/>(Reglas deterministas)"]
    A3 --> T4[("PostgreSQL: citas<br/>(Restricción única fecha/hora)")]
```

### Arquitectura 2: Jerárquica (`arch_jerarquica.py`)

Estructura de dos niveles de decisión: el Orquestador Raíz delega en un **Supervisor de Conocimiento** (FAQs y políticas) y un **Supervisor de Operaciones**, quien impone la secuencia obligatoria: `clima -> evaluación de seguridad -> agenda`.

```mermaid
graph TD
    U["Usuario"] <--> R["Orquestador Raíz<br/>(Dirección y Síntesis)"]
    
    R -->|as_tool| S1["Supervisor de Conocimiento<br/>(FAQs y Políticas)"]
    R -->|as_tool| S2["Supervisor de Operaciones<br/>(Impositor de secuencia técnica)"]

    S1 -->|as_tool| H1["Agente FAQs Hoja"]
    S1 -->|as_tool| H2["Agente Políticas Hoja"]

    S2 -->|as_tool: 1. Clima| H3["Agente Clima Hoja"]
    S2 -->|as_tool: 2. Veredicto| H4["Agente Evaluación Hoja"]
    S2 -->|as_tool: 3. Reserva| H5["Agente Agenda Hoja"]

    H1 --> T1[("PostgreSQL + pgvector<br/>faqs")]
    H3 --> T2["API Open-Meteo<br/>(08-16h)"]
    H4 --> T3["core/safety.py<br/>(Veredicto Python)"]
    H5 --> T4[("PostgreSQL: citas<br/>(Transaccional)")]
```

### Arquitectura 3: Descentralizada (`arch_descentralizada.py`)

Red de pares autónomos sin coordinador permanente. La atención inicia en `agente_faqs` y el control se transfiere dinámicamente mediante `handoff()` según el dominio requerido.

```mermaid
graph LR
    U["Usuario"] <--> F["Agente FAQs<br/>(Receptor inicial)"]
    
    F <-->|handoff: clima / viabilidad| C["Agente Clima / Seguridad"]
    C <-->|handoff: reservar con evidencia| A["Agente Agenda / Citas"]
    A <-->|handoff: dudas institucionales| F
    A <-->|handoff: falta evidencia clima| C

    F --> T1[("PostgreSQL + pgvector<br/>faqs")]
    C --> T2["API Open-Meteo + safety.py"]
    A --> T3[("PostgreSQL: citas<br/>(Guardarraíl determinista)")]
```

---

## 2. Decisiones Técnicas y Guardarraíles Críticos

1. **Evaluación de Seguridad Determinista en Python Puro (`core/safety.py`)**:
   - El LLM **nunca** calcula ni relaja umbrales de seguridad.
   - Viento: `< 20 km/h` (IDEAL), `20–28 km/h` (MARGINAL: solo tándem experimentado), `> 28 km/h` (PROHIBIDO).
   - Ráfagas: `> 35 km/h` (PROHIBIDO).
   - Precipitación: `> 0.0 mm` (PROHIBIDO).
   - Nubes: `< 30%` (IDEAL), `30–75%` (MARGINAL), `> 75%` (PROHIBIDO).
   - Temperatura: Informativa, sin veto.
   - Veredicto global: El **peor** de los estados individuales.

2. **Ventana Operativa de Salto (08:00–16:00) vs Agregación Diaria 24h**:
   - En las coordenadas del Pacífico guatemalteco (`14.013722, -90.771611`), la temporada lluviosa de septiembre/octubre presenta chubascos nocturnos y nubosidad de tormenta que provocarían que `precipitation_sum > 0` y `cloud_cover_max > 75%` en prácticamente el 100% de los días a nivel de 24 horas.
   - Por ello, el sistema adopta como modo principal la **agregación sobre la franja diurna operativa (08:00 a 16:00)** consultando las variables horarias de Open-Meteo. También se soporta modo `--mock-clima ideal|marginal|prohibido` para pruebas reproducibles.

3. **Invariante de Evidencia Meteorológica por Turno**:
   - Para evitar fallos de red o latencia al confirmar citas, la evidencia meteorológica obtenida es válida durante todo el turno de conversación.
   - La función `agendar_cita` verifica que: `fecha_cita == fecha_evidencia`, `coords == coords_base` y `veredicto != PROHIBIDO`.

4. **Persistencia Transaccional con Restricción Única**:
   - Tabla `citas` en PostgreSQL con restricción `UNIQUE (fecha, hora)` que impide sobrecupos (1 cita por franja de 1 hora, 8 franjas diarias de 08:00 a 15:00).
   - Idempotencia garantizada por clave única.

---

## 3. Instalación y Configuración

### 3.1 Entorno Virtual y Dependencias

```bash
python -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

### 3.2 Base de Datos PostgreSQL con pgvector

```bash
docker compose up -d
docker compose ps
```

### 3.3 Configuración del archivo `.env`

Copia el archivo de ejemplo:

```bash
cp .env.example .env
```

Configura tus credenciales en `.env`:
```dotenv
NVIDIA_API_KEY=<tu-clave-de-nvidia>
OPENAI_BASE_URL=https://integrate.api.nvidia.com/v1
MODEL=openai/gpt-oss-20b
DATABASE_URL=postgresql://parachute:parachutepass@localhost:5432/parachutedb
FAQ_TABLE=faqs
CITAS_TABLE=citas
```

---

## 4. Guía de Ejecución

### 4.1 Carga del Corpus de FAQs
Genera embeddings normalizados de 384 dimensiones y carga las 120 FAQs en PostgreSQL:
```bash
python main.py load
```

### 4.2 Prueba de Humo con Fallback de Modelos
Valida la conectividad a NVIDIA NIM y comprueba tool calling, `as_tool()`, `handoff()` y desactivación de telemetría:
```bash
python main.py smoke-test
```

### 4.3 Ejecución del Chat en las Tres Arquitecturas

- **Arquitectura Centralizada (predeterminada)**:
  ```bash
  python main.py chat --arquitectura centralizada
  ```
- **Arquitectura Jerárquica**:
  ```bash
  python main.py chat --arquitectura jerarquica
  ```
- **Arquitectura Descentralizada**:
  ```bash
  python main.py chat --arquitectura descentralizada
  ```

*Nota: También puedes ejecutar directamente `python arch_centralizada.py`, `python arch_jerarquica.py` o `python arch_descentralizada.py`.*

### 4.4 Pruebas Automatizadas
Ejecuta la suite completa de 39 pruebas unitarias y de integración (casos frontera de seguridad, fechas relativas, concurrencia de reservas y aislamiento de FAQs):
```bash
pytest tests/
```

### 4.5 Benchmark Comparativo de Arquitecturas
Ejecuta la matriz comparativa de latencia y respuestas:
```bash
python main.py benchmark
```
Los resultados observados se almacenan en `data/comparativa_arquitecturas.json`.
