/* fib.c -- recursion vs. iteration.  The recursive fib_r exercises the call/
 * ret/push/pop stack discipline hard (fib_r(15) makes 1973 calls), while the
 * iterative loop does the same work with a couple of registers.  A vivid demo
 * of how much the machine does for a "simple" recursive definition.          */
static int fib_r(int n) {
    if (n < 2) return n;
    return fib_r(n - 1) + fib_r(n - 2);         /* two recursive calls        */
}

void run(void) {
    volatile int *out = (int *)0x800;
    out[0] = fib_r(10);                         /* 55                         */

    int a = 0, b = 1;                           /* iterative                  */
    for (int i = 0; i < 10; i++) {
        int t = a + b;
        a = b;
        b = t;
    }
    out[1] = a;                                 /* 55  (matches the recursion)*/

    out[2] = fib_r(15);                         /* 610                        */
}
