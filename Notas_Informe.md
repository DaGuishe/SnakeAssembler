# Notas para el informe — Parcial 3 Snake (Sandoval – Gonzalez)

## 1. Errores intencionales encontrados

### En `interrupt_template_v4.s`

| # | Línea aprox. | Error | Corrección |
|---|---|---|---|
| 1 | 91 | La pila SVC apunta a `0xFFFFFFFC`, el mismo tope que la pila IRQ. La primera interrupción pisa la pila del programa principal. | Pila SVC en `0x3FFFFFFC` (tope de la DDR); la IRQ se queda en la memoria interna (`0xFFFFFFFC`). |
| 2 | 264 / 295 | El despachador `SERVICE_IRQ` solo guarda R0–R7. R8–R12 son los registros globales del juego (contador, cabeza, dirección); cualquier ISR que los use corrompe la partida. | `PUSH/POP {R0-R12, LR}`. |
| 3 | 290 | Un identificador desconocido (p. ej. 1023, interrupción espuria) deja el programa en un bucle infinito dentro del modo IRQ. | Se ignora y se sale por `EXIT_IRQ`. |
| 4 | 523 | `dir_pendiente_x` empieza en 0. Con el bloque de sincronización, el primer cuadro aplica la dirección (0, 0) y la serpiente se queda quieta. | Valor inicial 1, igual a la dirección inicial; además, el MainLoop ignora la dirección (0, 0). |

### En `snakelogic_v4.s`

| # | Línea aprox. | Error | Corrección |
|---|---|---|---|
| 5 | 189 y 194 | `Check_Keyboard`: las flechas izquierda y derecha están invertidas (`moveq r11, #1` para la izquierda y `#-1` para la derecha). | El bloque se eliminó (Parte 2.3); `PS2_ISR` usa los valores correctos de la tabla. |
| 6 | 201–202 | La cabeza avanza 1 píxel por cuadro (`add r9, r9, r11`), pero todo lo demás está en una cuadrícula de 10 px: el autómata da pasos de 10 y las colisiones cola/autómata comparan igualdad exacta. La cola se veía como un rectángulo de 13 px y el autómata casi nunca coincidía con la serpiente. | `mla r9, r11, #BOX_SIZE, r9`: la cabeza avanza una casilla (10 px). |
| 7 | 126–129 | Al borrar la cola se saltaban los segmentos con x = 0 o y = 0 (`cmp/cmpne`). Además, como el historial empezaba en ceros, al arrancar se pintaba un cuadro gris en (0, 0) que nunca se borraba. | Se borra siempre, y el historial se inicializa con los 4 segmentos reales de la cola (`ResetGameState`). |
| 8 | 437–469 | `GenerateFood` usa `r8 + sp` como "aleatorio": la fruta no queda alineada a la cuadrícula y, con el reintento de la Parte 5.2, generaría siempre el mismo candidato (bucle infinito). | Generador congruente lineal con `semilla`, que avanza también mientras se espera en la pantalla de inicio. Las coordenadas son múltiplos de 10. |
| 9 | 83 | `_start` pone `sp = 0x800000`, que pisaría la pila SVC de la plantilla al fusionar. | Se eliminó; se usan las pilas de la plantilla. |
| 10 | 692 y 696 | La tabla de colores de la cabeza incluye amarillo (el color del autómata) y gris (el color de la cola), así que la cabeza se confunde con ellos. | Cambiados por violeta (`0x801F`) y verde lima (`0xAFE5`). |

### En los fragmentos de código del enunciado (también conviene mencionarlos)

- **2.1:** `POP {PCO}` debe ser `POP {PC}`, y la base `0xFF201000` (JTAG UART) debe ser `0xFF200100` (PS/2).
- **2.3:** los registros `R14` y `R21` deben ser `R11` y `R12`. Además, la lógica `CMP`/`CMPNE`/`MOVNE` está invertida. Se reemplazó por la prueba `candidata + actual == (0, 0)`.
- **3.2:**
  - `MOV R4, #8` debe ser `#1`.
  - `AND #0xFC` debe ser `#0xFF`.
  - `historial_po` debe ser `historial_pos`.
  - `ADD R4, R4, #0` debe ser `#1`.
  - `CSC_Hit` debe devolver 1.
  - En la llamada, `CMP R0, #0` debe ser `CMP R0, #1`.
- **3.3:** al reiniciar, `largo_cola` debe volver a 4 (el fragmento dice 0).
- **5.2:** `CheckCollisionWithSnake` devuelve el resultado en R0 y borra la x candidata, así que hay que guardar el candidato en R4 y R5.

## 2. Estrategia del autómata (`MoveBot`)

**Objetivo según la personalidad** (KEY3 alterna; HEX5 muestra **G** o **C**):
- **Glotona (0):** el objetivo es la fruta. Si cae sobre ella, crece una casilla (hasta 20) y se genera una fruta nueva.
- **Cazadora (1):** el objetivo es la casilla que la cabeza del jugador va a pisar en el cuadro siguiente: `cabeza + dirección × 10`. La idea es ponerse en el camino del jugador para que choque.

**Decisión: voraz por eje dominante.**
```
dx = objetivo_x - bot_x ;  dy = objetivo_y - bot_y
sx = signo(dx)*10 (o +10 si dx = 0) ;  sy = signo(dy)*10 (o +10 si dy = 0)
si |dx| >= |dy|:  opciones = [(sx,0), (0,sy), (0,-sy), (-sx,0)]
si no:            opciones = [(0,sy), (sx,0), (-sx,0), (0,-sy)]
para cada opción:
    si se sale de la pantalla -> descartar
    recordar la primera opción dentro de la pantalla (respaldo)
    si es cazadora (o GLOTONA_ESQUIVA = 1) y la casilla pisa la serpiente -> descartar
    si no -> elegirla
si ninguna sirve -> usar el respaldo
guardar bot_x, bot_y y registrar la posición en bot_historial (la cola)
```
Cumple las restricciones: el paso es siempre de 10 px en un solo eje, nunca sale de [0, 310] × [0, 230], y preserva R4–R7 (no toca R8–R12).

**Por qué la glotona no esquiva:** así se ve en la demostración la colisión autómata–serpiente, que llama a `ResetBot`. Con `GLOTONA_ESQUIVA = 1` también esquiva.

**Análisis cualitativo (completar con lo que observen):**
- Funciona bien en campo abierto: la distancia de Manhattan baja una casilla por cuadro y nunca se atasca contra una pared, gracias a las opciones de respaldo.
- La glotona choca con la cola cuando esta se interpone entre ella y la fruta (se reinicia en 200, 120).
- La cazadora falla por **paridad** en los choques de frente. Como está obligada a moverse en cada cuadro, si queda justo en la casilla objetivo tiene que salirse de ella. Le va mejor interceptando de lado.
- Comparación con "voraz primero en x": esa estrategia avanza en zig-zag y deja la caza para el final. El eje dominante reduce primero la distancia mayor y llega en el mismo número de pasos, pero la ruta es más directa y predecible.
- Observación experimental pendiente: cuántas frutas de cada 10 llega antes la glotona que el jugador.

## 3. Interrupciones frente a sondeo (para el análisis)

- Con sondeo, una tecla oprimida justo después de la consulta solo se atendía al cuadro siguiente, es decir, después del `Delay`. Ahora `PS2_ISR` la atiende al instante y deja la dirección en `dir_pendiente_x/y`; el MainLoop solo lee memoria.
- El CPU ya no gasta tiempo preguntando al PS/2 en cada vuelta.
- `TIMER_ISR`, a 1 Hz, actualiza los LED y HEX3–HEX0 sin que el juego tenga que hacerlo.
- `KEY_ISR` maneja reinicio (KEY0), pausa (KEY1) y personalidad (KEY3).
- `PS2_ISR` ignora los códigos de liberación (`F0`), así que soltar una tecla no produce efectos.

## 4. Bonificaciones implementadas

- **Bono 1:** el puntaje se dibuja píxel a píxel en la pantalla de fin de partida, con una fuente de 3×5 ampliada ×6.
- **Bono 2:** `velocidad_bot` sube a 2 pasos por cuadro cuando el puntaje pasa de 10.
- **Bono 3:** no implementado.
