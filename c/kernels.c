/* kernels.c -- small integer kernels compiled with gcc (-O0 and -O2) to run on
 * the teaching CPU, showing how optimization level changes the machine code.
 * Integer-only (no division): array sum/dot-product, factorial, struct access.
 * Results are stored at fixed addresses so the checker can verify them.      */
static int arr[8] = { 3, 1, 4, 1, 5, 9, 2, 6 };

static int sum_array(const int *a, int n) {
    int s = 0;
    for (int i = 0; i < n; i++) s += a[i];          /* scaled-index load + add */
    return s;
}
static int dot(const int *a, const int *b, int n) {
    int s = 0;
    for (int i = 0; i < n; i++) s += a[i] * b[i];   /* IMUL + accumulate */
    return s;
}
static int factorial(int n) {
    int f = 1;
    for (int i = 2; i <= n; i++) f *= i;            /* IMUL loop */
    return f;
}
struct point { int x, y; };
static int dist_sq(const struct point *p) {
    return p->x * p->x + p->y * p->y;               /* struct field * + add */
}

void run(void) {
    volatile int *out = (int *)0x800;
    out[0] = sum_array(arr, 8);                      /* 31 */
    out[1] = dot(arr, arr, 4);                       /* 9+1+16+1 = 27 */
    out[2] = factorial(5);                           /* 120 */
    struct point p = { 3, 4 };
    out[3] = dist_sq(&p);                            /* 25 */
}
