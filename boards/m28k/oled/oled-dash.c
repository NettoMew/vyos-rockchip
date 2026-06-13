// oled-dash: live system monitor for the M28K 0.91" OLED
// (SSD1306 128x32 via the ssd130x DRM fbdev /dev/fb0, 32bpp emulation).
//
// The whole 128x32 panel is Bongo Cat. The cat's paws tap the table at a rate set
// by CPU load: idle (<8%) it sits and breathes (the 5 idle frames ping-pong);
// busier, it taps -- faster the higher the load (the classic bongo-cat WPM gag).
// The frames are the well-known 1-bit bongo cat (see bongo_frames.h), blitted
// from their SSD1306 page layout each tick.
//
// In the empty bottom-right of the table a small status readout fades in & out
// (4x4 Bayer ordered-dither, the 1-bit way to fade), cycling clock / load / RAM /
// down / up / uptime. The frame is fully redrawn each tick and the panel rests
// periodically (burn-in care).
//
// BOTTOM LINE rotates through a different stat every few seconds -- net speed
// (v down / ^ up), load average, RAM used/total, date+time+weekday, uptime, then
// each NIC's IPv4.
//
// Build:  cc -O2 -o oled-dash oled-dash.c -lm

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/fb.h>
#include "bongo_frames.h"

static int fbfd=-1; static unsigned char *fbp,*shadow; static int W,H,STRIDE; static long SZ;

// 5x7 font: ' ' . % : 0-9 and the uppercase letters used by the rotating stats and
// NIC names (A B C D E G H I L M N O P R S T U W). NIC names are shown upper-cased.
static const unsigned char F_SP[7]={0,0,0,0,0,0,0};
static const unsigned char F_DOT[7]={0,0,0,0,0,0x0C,0x0C};
static const unsigned char F_PCT[7]={0x18,0x19,0x02,0x04,0x08,0x13,0x03};
static const unsigned char F_COL[7]={0,0x04,0x04,0,0x04,0x04,0};       // ':'
static const unsigned char F_DSH[7]={0,0,0,0x0E,0,0,0};                // '-'
static const unsigned char F_SLA[7]={0x01,0x02,0x02,0x04,0x08,0x08,0x10}; // '/'
static const unsigned char F_A[7]={0x0E,0x11,0x11,0x1F,0x11,0x11,0x11};
static const unsigned char F_B[7]={0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E};
static const unsigned char F_C[7]={0x0E,0x11,0x10,0x10,0x10,0x11,0x0E};
static const unsigned char F_D[7]={0x1C,0x12,0x11,0x11,0x11,0x12,0x1C};
static const unsigned char F_E[7]={0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F};
static const unsigned char F_F[7]={0x1F,0x10,0x10,0x1E,0x10,0x10,0x10};
static const unsigned char F_G[7]={0x0E,0x11,0x10,0x17,0x11,0x11,0x0E};
static const unsigned char F_H[7]={0x11,0x11,0x11,0x1F,0x11,0x11,0x11};
static const unsigned char F_I[7]={0x0E,0x04,0x04,0x04,0x04,0x04,0x0E};
static const unsigned char F_L[7]={0x10,0x10,0x10,0x10,0x10,0x10,0x1F};
static const unsigned char F_M[7]={0x11,0x1B,0x15,0x15,0x11,0x11,0x11};
static const unsigned char F_N[7]={0x11,0x19,0x19,0x15,0x13,0x13,0x11};
static const unsigned char F_O[7]={0x0E,0x11,0x11,0x11,0x11,0x11,0x0E};
static const unsigned char F_P[7]={0x1E,0x11,0x11,0x1E,0x10,0x10,0x10};
static const unsigned char F_R[7]={0x1E,0x11,0x11,0x1E,0x14,0x12,0x11};
static const unsigned char F_S[7]={0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E};
static const unsigned char F_T[7]={0x1F,0x04,0x04,0x04,0x04,0x04,0x04};
static const unsigned char F_U[7]={0x11,0x11,0x11,0x11,0x11,0x11,0x0E};
static const unsigned char F_W[7]={0x11,0x11,0x11,0x15,0x15,0x1B,0x11};
static const unsigned char F_K[7]={0x11,0x12,0x14,0x18,0x14,0x12,0x11};
static const unsigned char F_UP[7]={0x04,0x0E,0x15,0x04,0x04,0x04,0x04};   // up arrow  (^ = upload)
static const unsigned char F_DN[7]={0x04,0x04,0x04,0x04,0x15,0x0E,0x04};   // down arrow (v = download)
static const unsigned char F_DIG[10][7]={
	{0x0E,0x11,0x13,0x15,0x19,0x11,0x0E},{0x04,0x0C,0x04,0x04,0x04,0x04,0x0E},
	{0x0E,0x11,0x01,0x02,0x04,0x08,0x1F},{0x1F,0x02,0x04,0x02,0x01,0x11,0x0E},
	{0x02,0x06,0x0A,0x12,0x1F,0x02,0x02},{0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E},
	{0x06,0x08,0x10,0x1E,0x11,0x11,0x0E},{0x1F,0x01,0x02,0x04,0x08,0x08,0x08},
	{0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E},{0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C}};
static const unsigned char *glyph(char c){
	if(c>='0'&&c<='9')return F_DIG[c-'0'];
	switch(c){
		case '.':return F_DOT; case '%':return F_PCT; case ':':return F_COL;
		case '-':return F_DSH; case '/':return F_SLA;
		case 'A':return F_A; case 'B':return F_B; case 'C':return F_C; case 'D':return F_D;
		case 'E':return F_E; case 'F':return F_F; case 'G':return F_G; case 'H':return F_H;
		case 'I':return F_I; case 'L':return F_L; case 'M':return F_M; case 'N':return F_N;
		case 'O':return F_O; case 'P':return F_P; case 'R':return F_R; case 'S':return F_S;
		case 'T':return F_T; case 'U':return F_U; case 'W':return F_W; case 'K':return F_K;
		case '^':return F_UP; case 'v':return F_DN; }
	return F_SP; }

static long now_us(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec*1000000L+t.tv_nsec/1000; }
static void usleep_(long us){ if(us>0){ struct timespec t={us/1000000,(us%1000000)*1000}; nanosleep(&t,NULL);} }
static void setpx(int x,int y,int on){ if(x<0||y<0||x>=W||y>=H)return; *(unsigned int*)(shadow+(long)y*STRIDE+(long)x*4)= on?0xFFFFFFFFu:0u; }
static int  tw(const char*s){ int n=strlen(s); return n>0?n*6-1:0; }

static void present(void){ memcpy(fbp,shadow,SZ); msync(fbp,SZ,MS_SYNC); }
static void blank(int on){ if(fbfd>=0) ioctl(fbfd,FBIOBLANK,on?FB_BLANK_POWERDOWN:FB_BLANK_UNBLANK); }

static void mem_kb(long*used,long*total){ long t=0,a=0,v; char line[128]; *used=*total=-1;
	FILE*f=fopen("/proc/meminfo","r"); if(!f)return;
	while(fgets(line,sizeof line,f)){ if(sscanf(line,"MemTotal: %ld",&v)==1)t=v; else if(sscanf(line,"MemAvailable: %ld",&v)==1)a=v; }
	fclose(f); if(t<=0)return; *total=t; long u=t-a; *used=u<0?0:u; }
// Instantaneous CPU utilisation 0..100 (drives the bongo cat's tap speed); -1 first call.
static int cpu_pct(void){ static long pt=0,pi=0; long t=0,idle=0,u,n,s,i,io,ir,si,st; FILE*f=fopen("/proc/stat","r"); if(!f)return -1;
	if(fscanf(f,"cpu %ld %ld %ld %ld %ld %ld %ld %ld",&u,&n,&s,&i,&io,&ir,&si,&st)==8){t=u+n+s+i+io+ir+si+st;idle=i+io;} fclose(f);
	long dt=t-pt,di=idle-pi; pt=t; pi=idle; if(dt<=0)return -1; int p=(int)((dt-di)*100/dt); return p<0?0:(p>100?100:p); }

// Every non-loopback IPv4 with its (upper-cased) interface name.
#define MAXIP 6
static char g_ifs[MAXIP][12]; static char g_ips[MAXIP][24]; static int g_nips=0;
static void read_ips(void){ g_nips=0;
	FILE*f=popen("ip -4 -o addr show 2>/dev/null|awk '$2!=\"lo\"{split($4,a,\"/\");print $2, a[1]}'","r");
	if(!f)return;
	char ifn[32], ip[40];
	while(g_nips<MAXIP && fscanf(f,"%31s %39s",ifn,ip)==2){
		int j; for(j=0;j<(int)sizeof g_ifs[0]-1 && ifn[j];j++){ char c=ifn[j]; g_ifs[g_nips][j]=(c>='a'&&c<='z')?c-32:c; }
		g_ifs[g_nips][j]=0;
		strncpy(g_ips[g_nips],ip,sizeof g_ips[0]-1); g_ips[g_nips][sizeof g_ips[0]-1]=0;
		g_nips++; }
	pclose(f); }


// Blit a 128x32 bongo-cat frame (SSD1306 page layout) into the shadow buffer:
// byte i -> column i%128, page i/128; bit b lights row page*8+b.
static void draw_bongo(int idx){
	const unsigned char *f=BONGO[idx];
	for(int i=0;i<512;i++){ unsigned char b=f[i]; if(!b)continue;
		int col=i&127, base=(i>>7)*8;
		for(int bit=0;bit<8;bit++) if(b&(1<<bit)) setpx(col,base+bit,1); }
}

// Ordered-dither fade: draw a string at (x0,y0); alpha 0..1 ramps the pixels in
// via an 8x8 Bayer threshold (64 levels -> a fine, even dissolve) on 1-bit.
static const unsigned char BAYER8[8][8]={
	{ 0,32, 8,40, 2,34,10,42},{48,16,56,24,50,18,58,26},
	{12,44, 4,36,14,46, 6,38},{60,28,52,20,62,30,54,22},
	{ 3,35,11,43, 1,33, 9,41},{51,19,59,27,49,17,57,25},
	{15,47, 7,39,13,45, 5,37},{63,31,55,23,61,29,53,21}};
static void draw_text_fade(const char*s,int x0,int y0,float a){
	int th=(int)(a*65.0f); if(th<0)th=0; if(th>64)th=64;
	int gx=x0;
	for(const char*p=s;*p;p++,gx+=6){ const unsigned char*g=glyph(*p);
		for(int r=0;r<7;r++) for(int c=0;c<5;c++)
			if(g[r]&(1<<(4-c))){ int xx=gx+c,yy=y0+r;
				if(xx>=0&&xx<W&&yy>=0&&yy<H && BAYER8[yy&7][xx&7]<th) setpx(xx,yy,1); } }
}
// Corner status, cycled with a fade: page 0 = used memory; pages 1.. = each NIC's
// last two IPv4 octets, prefixed with the interface initial ("E100.221" eth0,
// "W100.243" wlan0). statpages() is 1 + the number of addressed interfaces.
static int statpages(void){ return 1 + g_nips; }
static void shortstat(int p,char*o,int n){
	if(p==0){ long u,t; mem_kb(&u,&t);
		if(t<0) snprintf(o,n,"R--"); else snprintf(o,n,"R%ld",(u+512)/1024);   // used MB, no unit
		return; }
	int k=p-1;
	if(k<0||k>=g_nips){ snprintf(o,n,"no-ip"); return; }
	const char*ip=g_ips[k], *d2=0,*d1=0;
	for(const char*q=ip;*q;q++) if(*q=='.'){ d2=d1; d1=q; }   // d2 = 2nd-to-last dot
	snprintf(o,n,"%c%s", g_ifs[k][0]?g_ifs[k][0]:'?', d2?d2+1:ip);
}

int main(void){
	fbfd=open("/dev/fb0",O_RDWR); if(fbfd<0)return 0;
	struct fb_var_screeninfo v; struct fb_fix_screeninfo fx;
	if(ioctl(fbfd,FBIOGET_VSCREENINFO,&v)||ioctl(fbfd,FBIOGET_FSCREENINFO,&fx))return 0;
	W=v.xres;H=v.yres;STRIDE=fx.line_length;SZ=(long)STRIDE*H; if(v.bits_per_pixel!=32)return 0;
	fbp=mmap(NULL,SZ,PROT_READ|PROT_WRITE,MAP_SHARED,fbfd,0); if(fbp==MAP_FAILED)return 0;
	shadow=malloc(SZ); if(!shadow)return 0;
	(void)system("for v in /sys/class/vtconsole/vtcon*/bind; do grep -q 'frame buffer' \"$(dirname \"$v\")/name\" 2>/dev/null && echo 0 > \"$v\"; done 2>/dev/null");

	const float FPS=60.0f;                        // frame rate
	memset(shadow,0,SZ);
	blank(0);

	float disp=0,target=0;                        // smoothed CPU% -> bongo cat tap speed
	char sb[24]={0}; int slast=-1; long sbuilt=-1000;              // cached corner-stat string
	read_ips();
	const long FRAME=(long)(1000000/FPS);
	long frame=0, next=now_us();
	static const int idleseq[8]={0,1,2,3,4,3,2,1};   // ping-pong through the idle frames

	for(;;){
		// CPU load drives the cat. Idle (<8%): cycle the calm idle frames. Busy: the
		// paws tap, faster the busier it is -- the classic bongo-cat WPM behaviour.
		if(frame%8==0){ int c=cpu_pct(); if(c>=0) target=(float)c; }
		disp+=(target-disp)*0.12f;
		if(frame%600==0) read_ips();   // re-enumerate NICs (a wlan0 may come/go)

		// periodic panel rest (burn-in): ~10s every 300s, not at boot
		long sec=frame/(long)FPS;
		if(frame>180 && sec%300>=290){ blank(1); usleep_(500000); frame+=30; next=now_us(); continue; }
		blank(0);

		int fr;
		if(disp<8.0f) fr=idleseq[(frame/16)%8];                         // calm idle loop (breathing)
		else { int period=(int)(15.0f-(disp-8.0f)*0.13f); if(period<3)period=3;   // tap interval (frames)
			fr=((frame/period)&1)? BONGO_TAP0+1 : BONGO_TAP0; }         // alternate the two tap poses

		memset(shadow,0,SZ);
		draw_bongo(fr);

		// fade-cycling status in the empty bottom-right of the table. The alpha ramp
		// is smootherstep-eased (gentle ease-in/out, no abrupt edges) so the dither
		// dissolve feels natural and silky.
		{ const int FADE=48, HOLD=110, CYC=FADE*2+HOLD;
		  int sp=(int)((frame/CYC)%statpages()), tt=(int)(frame%CYC);
		  float r = tt<FADE ? (float)tt/FADE : (tt<FADE+HOLD ? 1.0f : (float)(CYC-tt)/FADE);
		  float a = r*r*r*(r*(6.0f*r-15.0f)+10.0f);                 // smootherstep
		  if(sp!=slast || frame-sbuilt>15){ shortstat(sp,sb,sizeof sb); slast=sp; sbuilt=frame; }
		  draw_text_fade(sb,126-tw(sb),25,a); }

		present();
		next+=FRAME; long d=next-now_us(); if(d>0)usleep_(d); else next=now_us();
		frame++;
	}
	return 0;
}
