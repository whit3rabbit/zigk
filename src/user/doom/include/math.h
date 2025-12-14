// Minimal math.h for doomgeneric
#ifndef _MATH_H
#define _MATH_H

#define M_PI 3.14159265358979323846
#define M_PI_2 1.57079632679489661923
#define M_E 2.71828182845904523536
#define HUGE_VAL __builtin_huge_val()
#define INFINITY __builtin_inf()
#define NAN __builtin_nan("")

double sin(double x);
double cos(double x);
double tan(double x);
double asin(double x);
double acos(double x);
double atan(double x);
double atan2(double y, double x);

double sinh(double x);
double cosh(double x);
double tanh(double x);

double exp(double x);
double log(double x);
double log10(double x);
double pow(double base, double exp);
double sqrt(double x);

double fabs(double x);
double floor(double x);
double ceil(double x);
double fmod(double x, double y);
double round(double x);
double trunc(double x);

float sinf(float x);
float cosf(float x);
float tanf(float x);
float asinf(float x);
float acosf(float x);
float atanf(float x);
float atan2f(float y, float x);
float expf(float x);
float logf(float x);
float log10f(float x);
float powf(float base, float exp);
float sqrtf(float x);
float fabsf(float x);
float floorf(float x);
float ceilf(float x);
float fmodf(float x, float y);
float roundf(float x);
float truncf(float x);

int abs(int n);

#endif // _MATH_H
