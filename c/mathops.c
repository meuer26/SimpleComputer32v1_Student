/* mathops.c -- division, modulo, shifts, and signed/unsigned char widening.
 * These are exactly the operations gcc lowers to the F7 group (DIV/IDIV),
 * CDQ (sign-extend EAX into EDX:EAX before a signed divide), the shift group,
 * and MOVSX/MOVZX.  A constant divide (1000/7) lets students see gcc replace
 * the divide with a reciprocal-multiply + shift at -O2, while the variable
 * gcd() must use a real DIV.                                                 */
static unsigned gcd(unsigned a, unsigned b) {
    while (b) { unsigned t = a % b; a = b; b = t; }   /* DIV each iteration   */
    return a;
}

void run(void) {
    volatile int *out = (int *)0x800;
    out[0] = gcd(48, 36);               /* 12                                 */
    out[1] = 1000 / 7;                  /* 142  (const -> reciprocal mul @O2)  */
    out[2] = 1000 % 7;                  /* 6                                   */
    out[3] = (-100) / 3;                /* -33  (IDIV, CDQ first)              */
    out[4] = (-100) % 3;                /* -1                                  */
    out[5] = (1 << 10) | (256 >> 2);    /* 1024 | 64 = 1088  (shift group)     */
    signed char c = -5;
    out[6] = c;                         /* -5   (MOVSX byte -> int)            */
    unsigned char u = 200;
    out[7] = u * 3;                     /* 600  (MOVZX then IMUL)              */
}
