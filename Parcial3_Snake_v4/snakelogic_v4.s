//===================================================================
// Snake v4 - Logica del juego para DE1-SoC (ARM Cortex-A9)
// Parcial 3 - Arquitectura de Computadores UIS 2026
//
// GLOSARIO (los terminos en ingles se definen aqui una sola vez;
// despues de definidos se usan libremente en el resto del archivo)
//
//   sondeo (polling)      Preguntar repetidamente a un periferico si
//                         ya tiene un dato nuevo, desde el bucle
//                         principal.
//   cuadro (frame)        Una pasada completa del bucle principal.
//                         El contador de cuadros va en R8.
//   bandera (flag)        Variable que vale 0 o 1 y recuerda que algo
//                         ocurrio.
//   automata rival (bot)  Serpiente controlada por el programa, que
//                         compite contra la del jugador.
//   memoria de video      Zona de memoria cuyo contenido se ve
//     (framebuffer)       directamente en la pantalla VGA.
//   paso de fila (stride) Distancia en bytes entre el comienzo de una
//                         fila de pixeles y el de la siguiente.
//                         En esta tarjeta son 1024 bytes, aunque solo
//                         640 sean visibles.
//   arreglo circular      Arreglo que se recorre con un indice que,
//     (buffer circular)   al llegar al final, vuelve al comienzo.
//   caja envolvente       Prueba de solape entre dos rectangulos
//     (AABB)              alineados con los ejes.
//   acotar (clamp)        Forzar un valor a quedarse dentro de un
//                         rango.
//   voraz (greedy)        Estrategia que en cada paso toma la decision
//                         que parece mejor en ese momento, sin mirar
//                         mas adelante.
//
// CONTENIDO DEL ARCHIVO:
//   - _start: valores iniciales de los registros globales, primera
//     fruta y posicion inicial del automata rival.
//   - MainLoop: 7 fases (borrar, leer teclado, mover, limites,
//     colisiones, dibujar, pausa).
//   - Subrutinas de dibujo: DrawSquare, WritePixelSafe.
//   - Subrutinas del juego: GenerateFood, CheckCollision_FoodHead,
//     Delay.
//   - Subrutinas del automata rival: MoveBot (hay que implementarla),
//     CheckBotVsSnakeBody, CheckHeadVsBot, ResetBot.
//
// REGISTROS GLOBALES (uso fijo durante todo el MainLoop):
//   R7  = bandera E0        tecla extendida del PS/2 (solo con sondeo)
//   R8  = contador de cuadros (tambien sirve de semilla aleatoria)
//   R9  = cabeza_x          posicion horizontal de la cabeza
//   R10 = cabeza_y          posicion vertical de la cabeza
//   R11 = dir_x             direccion horizontal (-1, 0, +1)
//   R12 = dir_y             direccion vertical   (-1, 0, +1)
//
// AVISO: este archivo contiene errores intencionales que usted debe
//        identificar y corregir.
//===================================================================

// Constantes de pantalla
.equ WIDTH,              320
.equ HEIGHT,             240
.equ BOX_SIZE,           10
.equ FOOD_SIZE,          10
.equ BOX_MAX_X,          310        // WIDTH  - BOX_SIZE
.equ BOX_MAX_Y,          230        // HEIGHT - BOX_SIZE
.equ RAND_MAX_X_PLUS_1,  311        // WIDTH  - FOOD_SIZE + 1
.equ RAND_MAX_Y_PLUS_1,  231        // HEIGHT - FOOD_SIZE + 1

// Perifericos
.equ PIXBUF,             0xC8000000     // Memoria de video VGA
.equ PS2_BASE,           0xFF200100     // Controlador del teclado PS/2
.equ STACK_TOP,          0x800000       // Tope de pila del programa

// Colores de 16 bits en formato RGB565
.equ COLOR_BLACK,        0x0000
.equ COLOR_RED,          0xF800
.equ COLOR_GREEN,        0x07E0
.equ COLOR_BLUE,         0x001F
.equ COLOR_YELLOW,       0xFFE0          // Cabeza del automata rival
.equ COLOR_ORANGE,       0xFC00          // Cola del automata rival
.equ COLOR_GREY,         0x8410          // Cola de la serpiente del jugador

//===================================================================
.global _start
_start:
    ldr  sp, =STACK_TOP

    // Estado inicial
    mov  r7,  #0                    // bandera E0 = 0
    mov  r8,  #0                    // contador de cuadros = 0
    mov  r9,  #50                   // cabeza_x inicial
    mov  r10, #50                   // cabeza_y inicial
    mov  r11, #1                    // dir_x inicial (hacia la derecha)
    mov  r12, #0                    // dir_y inicial

    bl   GenerateFood               // Primera fruta
    bl   ResetBot                   // Posicion inicial del automata rival

//===================================================================
// BUCLE PRINCIPAL
//===================================================================
MainLoop:

    //----------------------------------------------------------------
    // FASE 1 - BORRAR LOS OBJETOS DEL CUADRO ANTERIOR
    //----------------------------------------------------------------

    // 1a. Borrar la cabeza anterior
    mov  r0, r9
    mov  r1, r10
    mov  r2, #COLOR_BLACK
    bl   DrawSquare

    // 1b. Borrar la cola anterior
    ldr  r0, =largo_cola
    ldr  r4, [r0]                   // r4 = n (longitud de la cola)
    ldr  r0, =indice_historial
    ldr  r6, [r0]                   // r6 = indice de la cabeza anterior
    mov  r5, #1
CleanTail_Loop:
    cmp  r5, r4
    bgt  CleanTail_End
    sub  r0, r6, r5
    and  r0, r0, #0xFF              // indice dentro del arreglo circular
    ldr  r3, =historial_pos
    add  r3, r3, r0, lsl #3
    ldr  r0, [r3, #0]               // x de la cola anterior
    ldr  r1, [r3, #4]               // y de la cola anterior
    cmp  r0, #0
    cmpne r1, #0
    movne r2, #COLOR_BLACK
    blne DrawSquare
    add  r5, r5, #1
    b    CleanTail_Loop
CleanTail_End:

    // 1c. Borrar la fruta anterior
    ldr  r0, =fruta_x
    ldr  r0, [r0]
    ldr  r1, =fruta_y
    ldr  r1, [r1]
    mov  r2, #COLOR_BLACK
    bl   DrawSquare

    // 1d. Borrar el automata rival anterior
    ldr  r0, =bot_x
    ldr  r0, [r0]
    ldr  r1, =bot_y
    ldr  r1, [r1]
    mov  r2, #COLOR_BLACK
    bl   DrawSquare

    //----------------------------------------------------------------
    // FASE 2 - LEER EL TECLADO POR SONDEO
    //
    //  EN EL PARCIAL: este bloque completo DEBE ELIMINARSE y
    //  reemplazarse por el bloque de sincronizacion con las variables
    //  dir_pendiente_x y dir_pendiente_y, que escribe PS2_ISR en
    //  interrupt_template_v4.s. Ver la Parte 2.3 del enunciado.
    //
    //  ESTE BLOQUE CONTIENE AL MENOS UN ERROR INTENCIONAL.
    //----------------------------------------------------------------
Check_Keyboard:
    ldr  r0, =PS2_BASE
    ldr  r1, [r0]
    tst  r1, #0x8000
    beq  ReadKey_End

    and  r0, r1, #0xFF              // byte recibido

    cmp  r7, #1
    beq  Handle_E0_Key

    cmp  r0, #0xE0
    moveq r7, #1
    b    ReadKey_End

Handle_E0_Key:
    mov  r7, #0                     // Limpiar la bandera E0
    // Flecha arriba 0x75 -> direccion (0, -1)
    cmp  r0, #0x75
    moveq r11, #0
    moveq r12, #-1
    beq  ReadKey_End
    // Flecha abajo 0x72 -> direccion (0, +1)
    cmp  r0, #0x72
    moveq r11, #0
    moveq r12, #1
    beq  ReadKey_End
    // Flecha izquierda 0x6B -> direccion (-1, 0)
    cmp  r0, #0x6B
    moveq r11, #1
    moveq r12, #0
    beq  ReadKey_End
    // Flecha derecha 0x74 -> direccion (+1, 0)
    cmp  r0, #0x74
    moveq r11, #-1
    moveq r12, #0
ReadKey_End:

    //----------------------------------------------------------------
    // FASE 3 - ACTUALIZAR LA POSICION DE LA CABEZA
    //----------------------------------------------------------------
    add  r9,  r9,  r11
    add  r10, r10, r12

    //----------------------------------------------------------------
    // FASE 4 - COMPROBAR LIMITES
    //
    //   EN EL PARCIAL: este bloque debe reemplazarse. Las
    //   instrucciones MOVGT y MOVLT hacen que la serpiente rebote
    //   contra el borde; deben cambiarse por saltos a GameOver, de
    //   modo que tocar un borde termine la partida.
    //   La especificacion esta en la Parte 3.1 del enunciado.
    //----------------------------------------------------------------
    ldr  r0, =BOX_MAX_X
    cmp  r9, r0
    movgt r11, #-1
    movgt r9, r0
    cmp  r9, #0
    movlt r11, #1
    movlt r9, #0

    ldr  r0, =BOX_MAX_Y
    cmp  r10, r0
    movgt r12, #-1
    movgt r10, r0
    cmp  r10, #0
    movlt r12, #1
    movlt r10, #0

    //----------------------------------------------------------------
    // FASE 5 - ACTUALIZAR EL HISTORIAL DE POSICIONES DE LA COLA
    //----------------------------------------------------------------
    add  r6, r6, #1
    and  r6, r6, #0xFF              // indice circular (0 a 255)

    ldr  r4, =historial_pos
    add  r4, r4, r6, lsl #3
    str  r9,  [r4, #0]
    str  r10, [r4, #4]

    ldr  r0, =indice_historial
    str  r6, [r0]                   // actualizar el indice global

    //----------------------------------------------------------------
    // FASE 5b - COLISION ENTRE LA CABEZA Y LA FRUTA
    //----------------------------------------------------------------
    bl   CheckCollision_FoodHead
    cmp  r0, #1
    bne  Skip_Eat

    bl   GenerateFood
    ldr  r0, =largo_cola
    ldr  r5, [r0]
    add  r5, r5, #1
    str  r5, [r0]
Skip_Eat:

    //----------------------------------------------------------------
    // FASE 5c - AUTOMATA RIVAL: MOVER Y COMPROBAR COLISIONES
    //
    // Secuencia:
    //   1) MoveBot             -> un paso hacia donde decida su
    //                             estrategia
    //   2) CheckBotVsSnakeBody -> si el automata toco la cabeza o la
    //                             cola del jugador, se reinicia
    //   3) CheckHeadVsBot      -> si la cabeza del jugador toco al
    //                             automata, termina la partida
    //
    //  La estrategia de MoveBot es responsabilidad del grupo.
    //----------------------------------------------------------------

    // 5c-1. Mover el automata un paso (estrategia definida por el grupo)
    bl   MoveBot

    // 5c-2. El automata choco con la cabeza o la cola? -> reiniciarlo
    bl   CheckBotVsSnakeBody
    cmp  r0, #1
    bleq ResetBot

    // 5c-3. La cabeza choco con el automata? -> fin de la partida
    bl   CheckHeadVsBot
    cmp  r0, #1
    beq  GameOver_Stub              // En el parcial: saltar al GameOver real

    //----------------------------------------------------------------
    // FASE 6 - DIBUJAR LOS OBJETOS EN SU NUEVA POSICION
    //----------------------------------------------------------------

    // 6a. Dibujar la fruta (el color alterna segun la paridad del cuadro)
    ldr  r0, =fruta_x
    ldr  r0, [r0]
    ldr  r1, =fruta_y
    ldr  r1, [r1]
    ldr  r4, =tabla_colores
    tst  r8, #1
    ldreq r2, [r4, #8]              // cuadro par -> azul
    ldrne r2, [r4, #0]              // cuadro impar -> rojo
    bl   DrawSquare

    // 6b. Dibujar la cabeza (color ciclico, indice = bits 0 a 2 del cuadro)
    mov  r0, r9
    mov  r1, r10
    and  r3, r8, #0x7
    ldr  r4, =tabla_colores
    ldr  r2, [r4, r3, lsl #2]
    bl   DrawSquare

    // 6c. Dibujar la cola
    ldr  r0, =largo_cola
    ldr  r5, [r0]
    mov  r4, #1
DrawTail_Loop:
    cmp  r4, r5
    bgt  DrawTail_End

    sub  r0, r6, r4
    and  r0, r0, #0xFF
    ldr  r3, =historial_pos
    add  r3, r3, r0, lsl #3
    ldr  r0, [r3, #0]
    ldr  r1, [r3, #4]
    mov  r2, #COLOR_GREY
    bl   DrawSquare

    add  r4, r4, #1
    b    DrawTail_Loop
DrawTail_End:

    // 6d. Dibujar el automata rival (cuadrado amarillo)
    ldr  r0, =bot_x
    ldr  r0, [r0]
    ldr  r1, =bot_y
    ldr  r1, [r1]
    mov  r2, #COLOR_YELLOW
    bl   DrawSquare

    //----------------------------------------------------------------
    // FASE 7 - PAUSA Y CONTADOR DE CUADROS
    //----------------------------------------------------------------
    add  r8, r8, #1
    mov  r0, #50000
    bl   Delay

    b    MainLoop

//===================================================================
// GameOver_Stub - marcador de posicion
// En el parcial se reemplaza por la rutina GameOver de verdad
// (Parte 3.3 del enunciado), que escribe estado_juego = 1 y entra al
// bucle GameOver_Loop a esperar la tecla de reinicio.
//===================================================================
GameOver_Stub:
    b    GameOver_Stub              // Bucle infinito provisional

//===================================================================
// SUBRUTINAS - DIBUJO
//===================================================================

// DrawSquare(r0=x, r1=y, r2=color)
// Dibuja un cuadrado de BOX_SIZE por BOX_SIZE pixeles.
DrawSquare:
    push {r4-r7, lr}
    mov  r4, r0                     // x inicial
    mov  r5, r1                     // y inicial
    mov  r6, r2                     // color

    mov  r7, #0                     // contador vertical
DrawSq_Y:
    cmp  r7, #BOX_SIZE
    bge  DrawSq_End
    mov  r3, #0                     // contador horizontal
DrawSq_X:
    cmp  r3, #BOX_SIZE
    bge  DrawSq_NextY
    add  r0, r4, r3
    add  r1, r5, r7
    mov  r2, r6
    bl   WritePixelSafe
    add  r3, r3, #1
    b    DrawSq_X
DrawSq_NextY:
    add  r7, r7, #1
    b    DrawSq_Y
DrawSq_End:
    pop  {r4-r7, lr}
    bx   lr


// WritePixelSafe(r0=x, r1=y, r2=color)
// Escribe un pixel solo si la coordenada cae dentro de la pantalla.
WritePixelSafe:
    push {r3-r5}
    ldr  r3, =(WIDTH-1)             // 319
    cmp  r0, r3
    bgt  WPS_End
    cmp  r0, #0
    blt  WPS_End
    ldr  r3, =(HEIGHT-1)            // 239
    cmp  r1, r3
    bgt  WPS_End
    cmp  r1, #0
    blt  WPS_End
    lsl  r3, r1, #10                // y * 1024 (paso de fila en bytes)
    add  r3, r3, r0, lsl #1         // + x * 2 (dos bytes por pixel)
    ldr  r4, =PIXBUF
    add  r3, r4, r3
    strh r2, [r3]
WPS_End:
    pop  {r3-r5}
    bx   lr

//===================================================================
// SUBRUTINAS - UTILIDADES
//===================================================================

// Delay(r0 = numero de vueltas) - pausa por conteo
Delay:
    push {r1}
    mov  r1, #0
Delay_Loop:
    add  r1, r1, #1
    cmp  r1, r0
    blt  Delay_Loop
    pop  {r1}
    bx   lr

//===================================================================
// SUBRUTINAS - FRUTA
//===================================================================

// GenerateFood - elige una posicion pseudoaleatoria para la fruta.
// Usa el contador de cuadros (r8) y el puntero de pila como semillas.
//
//  EN EL PARCIAL (Parte 5.2): modifique esta rutina para que vuelva a
//  intentar si la posicion generada coincide con algun segmento de la
//  serpiente (cabeza o cola). Hay que implementar la subrutina
//  CheckCollisionWithSnake.
GenerateFood:
    push {lr}

    // x dentro de [0, 310], calculado como resto de la division por 311
    mov  r0, r8
    add  r0, r0, sp
    ldr  r1, =RAND_MAX_X_PLUS_1
GF_DivX:
    cmp  r0, r1
    blt  GF_DoneX
    sub  r0, r0, r1
    b    GF_DivX
GF_DoneX:

    // y dentro de [0, 230]
    mov  r1, r8
    lsl  r1, r1, #4
    add  r1, r1, sp
    ldr  r2, =RAND_MAX_Y_PLUS_1
GF_DivY:
    cmp  r1, r2
    blt  GF_DoneY
    sub  r1, r1, r2
    b    GF_DivY
GF_DoneY:

    ldr  r2, =fruta_x
    str  r0, [r2]
    ldr  r2, =fruta_y
    str  r1, [r2]

    pop  {lr}
    bx   lr

//===================================================================
// SUBRUTINAS - COLISION ENTRE LA CABEZA Y LA FRUTA
//===================================================================

// CheckCollision_FoodHead
// Caja envolvente entre la cabeza (10 x 10) y la fruta (10 x 10).
// Devuelve: r0 = 1 si hay colision, r0 = 0 si no la hay.
CheckCollision_FoodHead:
    push {r1-r5, lr}

    ldr  r1, =fruta_x
    ldr  r1, [r1]                   // r1 = fruta_x
    ldr  r2, =fruta_y
    ldr  r2, [r2]                   // r2 = fruta_y

    mov  r0, #0

    add  r3, r1, #FOOD_SIZE         // borde derecho de la fruta
    add  r4, r9, #BOX_SIZE          // borde derecho de la cabeza
    add  r5, r2, #FOOD_SIZE         // borde inferior de la fruta

    cmp  r9, r3
    bge  CFH_No
    cmp  r4, r1
    ble  CFH_No
    cmp  r10, r5
    bge  CFH_No
    add  r3, r10, #BOX_SIZE         // borde inferior de la cabeza
    cmp  r3, r2
    ble  CFH_No

    mov  r0, #1
CFH_No:
    pop  {r1-r5, lr}
    bx   lr

//===================================================================
// SUBRUTINAS - AUTOMATA RIVAL
//
// Estas cuatro subrutinas son todo lo que el automata necesita.
//   Tres de ellas ya estan implementadas y NO deben modificarse:
//     CheckBotVsSnakeBody, CheckHeadVsBot, ResetBot.
//   La cuarta, MoveBot, esta vacia y usted debe llenarla con la
//   estrategia de decision que su grupo disene (Parte 4 del parcial).
//===================================================================

//-------------------------------------------------------------------
// MoveBot - SUBRUTINA VACIA. EL GRUPO DEBE IMPLEMENTARLA.
//-------------------------------------------------------------------
// Proposito: avanzar UN paso de BOX_SIZE pixeles desde (bot_x, bot_y)
//            hacia (fruta_x, fruta_y), segun la logica que el grupo
//            decida e implemente.
//
// Entradas (en memoria):
//   bot_x, bot_y, fruta_x, fruta_y, indice_historial, largo_cola,
//   historial_pos (puede usarlas para esquivar la cola si su
//   estrategia lo necesita).
//
// Entradas (en registros vivos):
//   R8       = contador de cuadros (util para alternar de eje)
//   R9, R10  = cabeza de la serpiente (util para evitarla o
//              perseguirla)
//
// Salidas:
//   bot_x y bot_y actualizados en memoria.
//
// Restricciones obligatorias:
//   - El paso es de exactamente BOX_SIZE pixeles por llamada, y se
//     mueve solo en x o solo en y: nunca en diagonal.
//   - Acotar el resultado a [0, BOX_MAX_X] y [0, BOX_MAX_Y].
//   - Preservar los registros que use: push y pop de {r4-r7, lr}.
//
// Estrategias sugeridas (elija una y justifiquela en el informe):
//   (a) Voraz, primero en horizontal: alinear primero en x, luego en y.
//   (b) Voraz, primero en vertical  : alinear primero en y, luego en x.
//   (c) Alternada por paridad       : usar R8 para cambiar de eje
//       prioritario en cada cuadro.
//   (d) Evasiva                     : si el paso que parece mejor
//       caeria sobre un segmento de historial_pos, usar la otra
//       direccion.
//   (e) Una propia, justificada en el informe.
//-------------------------------------------------------------------
MoveBot:
    push {r4-r7, lr}

    //   ESCRIBA AQUI SU IMPLEMENTACION
    //
    //   Tal como viene, esta subrutina no hace nada y el automata se
    //   queda quieto. Eso NO se acepta como entrega: el automata debe
    //   perseguir activamente la fruta. Reemplace este comentario por
    //   su codigo de decision y la actualizacion de bot_x y bot_y.

    pop  {r4-r7, lr}
    bx   lr

//-------------------------------------------------------------------
// CheckBotVsSnakeBody - YA IMPLEMENTADA. NO MODIFICAR.
//-------------------------------------------------------------------
// Compara (bot_x, bot_y) contra la cabeza (R9, R10) y contra cada
// segmento vivo de historial_pos.
// Devuelve: R0 = 1 si hay colision, R0 = 0 si no la hay.
//-------------------------------------------------------------------
CheckBotVsSnakeBody:
    push {r1-r7, lr}

    ldr  r0, =bot_x
    ldr  r4, [r0]                   // r4 = bot_x
    ldr  r0, =bot_y
    ldr  r5, [r0]                   // r5 = bot_y

    // Comparar contra la CABEZA
    cmp  r4, r9
    bne  CBVSB_CheckTail
    cmp  r5, r10
    beq  CBVSB_Hit

CBVSB_CheckTail:
    // Comparar contra cada segmento de la COLA
    ldr  r0, =largo_cola
    ldr  r6, [r0]                   // r6 = n
    ldr  r0, =indice_historial
    ldr  r7, [r0]                   // r7 = indice actual de la cabeza
    mov  r3, #1                     // i = 1 (primer segmento de cola)

CBVSB_Loop:
    cmp  r3, r6
    bgt  CBVSB_NoHit

    sub  r0, r7, r3
    and  r0, r0, #0xFF              // indice circular
    ldr  r1, =historial_pos
    add  r1, r1, r0, lsl #3
    ldr  r0, [r1, #0]               // x del segmento
    ldr  r1, [r1, #4]               // y del segmento

    cmp  r4, r0
    bne  CBVSB_Next
    cmp  r5, r1
    beq  CBVSB_Hit

CBVSB_Next:
    add  r3, r3, #1
    b    CBVSB_Loop

CBVSB_Hit:
    mov  r0, #1
    pop  {r1-r7, lr}
    bx   lr

CBVSB_NoHit:
    mov  r0, #0
    pop  {r1-r7, lr}
    bx   lr

//-------------------------------------------------------------------
// CheckHeadVsBot - YA IMPLEMENTADA. NO MODIFICAR.
//-------------------------------------------------------------------
// Caja envolvente entre la cabeza (R9, R10) y el automata rival
// (bot_x, bot_y), ambos cuadrados de BOX_SIZE por BOX_SIZE.
// Devuelve: R0 = 1 si hay colision (fin de partida), R0 = 0 si no.
//-------------------------------------------------------------------
CheckHeadVsBot:
    push {r1-r5, lr}

    ldr  r0, =bot_x
    ldr  r1, [r0]                   // r1 = bot_x
    ldr  r0, =bot_y
    ldr  r2, [r0]                   // r2 = bot_y

    mov  r0, #0                     // suponer que no hay colision

    add  r3, r1, #BOX_SIZE          // borde derecho del automata
    add  r4, r9, #BOX_SIZE          // borde derecho de la cabeza

    cmp  r9, r3
    bge  CHVB_End                   // la cabeza esta a la derecha: no hay
    cmp  r4, r1
    ble  CHVB_End                   // la cabeza esta a la izquierda: no hay

    add  r3, r2, #BOX_SIZE          // borde inferior del automata
    add  r5, r10, #BOX_SIZE         // borde inferior de la cabeza

    cmp  r10, r3
    bge  CHVB_End
    cmp  r5, r2
    ble  CHVB_End

    mov  r0, #1                     // hay colision

CHVB_End:
    pop  {r1-r5, lr}
    bx   lr

//-------------------------------------------------------------------
// ResetBot - YA IMPLEMENTADA. NO MODIFICAR.
//-------------------------------------------------------------------
// Devuelve el automata rival a la posicion fija (200, 120). Se llama
// cuando CheckBotVsSnakeBody devuelve 1.
//-------------------------------------------------------------------
ResetBot:
    push {r0-r1, lr}
    ldr  r0, =bot_x
    mov  r1, #200
    str  r1, [r0]
    ldr  r0, =bot_y
    mov  r1, #120
    str  r1, [r0]
    pop  {r0-r1, lr}
    bx   lr

//===================================================================
// SECCION DE DATOS
//===================================================================
.data
.align 2

// Tabla de 8 colores para la cabeza (se recorre ciclicamente)
tabla_colores:
    .word 0xF800    // 0: rojo
    .word 0x07E0    // 1: verde
    .word 0x001F    // 2: azul
    .word 0xFFE0    // 3: amarillo
    .word 0xF81F    // 4: magenta
    .word 0x07FF    // 5: cian
    .word 0xFFFF    // 6: blanco
    .word 0x8410    // 7: gris

// Variables de la fruta
.align 2
fruta_x:           .word 0
fruta_y:           .word 0

// Variables de la serpiente del jugador
largo_cola:        .word 4      // longitud inicial de la cola
indice_historial:  .word 0      // indice circular dentro de historial_pos

// Variables del automata rival
.align 2
bot_x:             .word 200    // x inicial del automata
bot_y:             .word 120    // y inicial del automata

// Arreglo circular con las posiciones de la cola
// (256 entradas de 8 bytes: 4 para x y 4 para y)
.align 4
historial_pos:     .space (256 * 8)
