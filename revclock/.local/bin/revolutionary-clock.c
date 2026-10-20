/* Revolutionary Clock — C/GTK4 + gtk4-layer-shell port.
 * Port of AbuYahyaa's "Cups and Saucers" conky theme (GPLv3).
 * Anchored to the desktop bottom layer, redraws 1x/sec.
 * Compile:
 *   gcc -O2 -o ~/.local/bin/revolutionary-clock revolutionary-clock.c \
 *       $(pkg-config --cflags --libs gtk4 gtk4-layer-shell) -lm
 */
#include <gtk/gtk.h>
#include <gtk4-layer-shell.h>
#include <cairo.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/statvfs.h>

#define SCALE 2.0
#define SIZE  ((int)(280 * SCALE))
#define FONT  "hooge 05_53"

typedef struct {
    const char *name, *arg;
    int   max_value;
    double x, y;
    double cup_radius, cup_wall_thickness;
    double total_angle, cup_start_angle;
    uint32_t cup_bg_clr; int cup_bg_alpha;
    uint32_t cup_fg_clr; int cup_fg_alpha;
    double handle_length, handle_circ;
    uint32_t handle_fg_clr; int handle_fg_alpha;
    double graduation_radius, graduation_thickness, graduation_mark_circ, graduation_mark_angle;
    uint32_t graduation_fg_clr; int graduation_fg_alpha;
    double saucer_thickness, thick_saucer_circ, saucer_radius, thin_saucer_circ;
    uint32_t saucer_fg_clr; int saucer_fg_alpha;
    uint32_t saucer_mark_fg_clr; int saucer_mark_fg_alpha;
    int inner_saucer;
    int txt_weight; double txt_size;
    uint32_t txt_fg_clr; int txt_fg_alpha;
    const char *caption, *caption2;
    double xtxt, ytxt;
} Cup;

#define UNUSED_COLOR 0  /* 0 == unset -> default white in draw */

static Cup cups[] = {
  {.name="time2",.arg="%I.%M",.max_value=12,.x=130,.y=130,
   .cup_radius=25,.cup_wall_thickness=90,.total_angle=360,
   .cup_bg_clr=0xffffff,.cup_bg_alpha=0,.cup_fg_clr=0xffffff,.cup_fg_alpha=0,
   .handle_length=50,.handle_circ=5,.handle_fg_clr=0xffffff,.handle_fg_alpha=1,
   .graduation_radius=-35+124,.graduation_thickness=5,.graduation_mark_circ=1.5,.graduation_mark_angle=30,
   .graduation_fg_clr=0xffffff,.graduation_fg_alpha=.5,
   .saucer_thickness=6,.thick_saucer_circ=11./12,.saucer_radius=-35+135,.thin_saucer_circ=11./12,
   .saucer_fg_clr=0xffffff,.saucer_fg_alpha=.3,.inner_saucer=1,
   .txt_weight=0,.txt_size=7,.txt_fg_clr=0xffffff,.txt_fg_alpha=0,.caption="",.caption2=""},
  {.name="time",.arg="%H",.max_value=12,.x=130,.y=130,
   .cup_radius=1,.cup_wall_thickness=3,.total_angle=360,
   .cup_bg_clr=0xffffff,.cup_bg_alpha=1,.cup_fg_clr=0xffffff,.cup_fg_alpha=1,
   .handle_length=-35+40,.handle_circ=4,.handle_fg_clr=0xffffff,.handle_fg_alpha=0,
   .graduation_radius=-35+127,.graduation_thickness=1,.graduation_mark_circ=.5,.graduation_mark_angle=3,
   .graduation_fg_clr=0xffffff,.graduation_fg_alpha=0,
   .saucer_thickness=6,.thick_saucer_circ=11./12,.saucer_radius=-35+135,.thin_saucer_circ=11./12,
   .saucer_fg_clr=0xffffff,.saucer_fg_alpha=0,.inner_saucer=1,
   .txt_weight=0,.txt_size=7,.txt_fg_clr=0xffffff,.txt_fg_alpha=0,.caption="",.caption2=""},
  {.name="time",.arg="%M",.max_value=60,.x=130,.y=130,
   .cup_radius=40,.cup_wall_thickness=120,.total_angle=360,
   .cup_bg_clr=0xffffff,.cup_bg_alpha=0,.cup_fg_clr=0xffffff,.cup_fg_alpha=0,
   .graduation_radius=-35+123,.graduation_thickness=7,.graduation_mark_circ=2,.graduation_mark_angle=90,
   .graduation_fg_clr=0xffffff,.graduation_fg_alpha=.5,
   .handle_length=80,.handle_circ=2,.handle_fg_clr=0xffffff,.handle_fg_alpha=1,
   .saucer_thickness=6,.thick_saucer_circ=11./12,.saucer_radius=-35+155,.thin_saucer_circ=11./12,
   .saucer_fg_clr=0xffffff,.saucer_fg_alpha=.3,
   .txt_weight=0,.txt_size=7,.txt_fg_clr=0xffffff,.txt_fg_alpha=0,.caption="",.caption2=""},
  {.name="time",.arg="%S",.max_value=60,.x=130,.y=130,
   .cup_radius=-17+59,.cup_wall_thickness=120,.total_angle=360,
   .cup_bg_clr=0xffffff,.cup_bg_alpha=0,.cup_fg_clr=0xffffff,.cup_fg_alpha=0,
   .handle_fg_clr=0xffffff,.handle_fg_alpha=1,.handle_length=-35+118,.handle_circ=1,
   .graduation_radius=-35+125,.graduation_thickness=3,.graduation_mark_circ=.5,.graduation_mark_angle=6,
   .graduation_fg_clr=0xffffff,.graduation_fg_alpha=.5,
   .saucer_thickness=5,.thick_saucer_circ=1,.saucer_radius=-35+145,.thin_saucer_circ=11./12,
   .saucer_fg_clr=0xffffff,.saucer_fg_alpha=.4,
   .saucer_mark_fg_clr=0xffffff,.saucer_mark_fg_alpha=.4,
   .txt_weight=0,.txt_size=7,.txt_fg_clr=0xffffff,.txt_fg_alpha=0,.caption="",.caption2=""},
  {.name="cpu",.arg="cpu0",.max_value=100,.x=130,.y=80,
   .cup_radius=20,.cup_wall_thickness=40,.total_angle=360,
   .cup_bg_clr=0xffffff,.cup_bg_alpha=0,.cup_fg_clr=0xffffff,.cup_fg_alpha=0,
   .handle_fg_clr=0xffffff,.handle_fg_alpha=0,.handle_length=40,.handle_circ=4,
   .xtxt=-15,.ytxt=-5,.txt_weight=0,.txt_size=7,
   .txt_fg_clr=0xffffff,.txt_fg_alpha=.8,.caption="CPU ",.caption2=" %",
   .graduation_radius=20,.graduation_thickness=3,.graduation_mark_circ=2,.graduation_mark_angle=36,
   .graduation_fg_clr=0xffffff,.graduation_fg_alpha=0,
   .saucer_thickness=3,.thick_saucer_circ=.85,.saucer_radius=25,.thin_saucer_circ=.85,
   .saucer_fg_clr=0xffffff,.saucer_fg_alpha=.3,
   .saucer_mark_fg_clr=0xffffff,.saucer_mark_fg_alpha=.5,.inner_saucer=1},
  {.name="freq_g",.arg="/",.max_value=5,.x=130,.y=80,
   .cup_radius=12,.cup_wall_thickness=23,.total_angle=360,
   .cup_bg_clr=0xffffff,.cup_bg_alpha=0,.cup_fg_clr=0xffffff,.cup_fg_alpha=0,
   .handle_fg_clr=0xffffff,.handle_fg_alpha=0,.handle_length=40,.handle_circ=4,
   .xtxt=-15,.ytxt=7,.txt_weight=0,.txt_size=7,
   .txt_fg_clr=0xffffff,.txt_fg_alpha=.8,.caption="",.caption2=" GHz",
   .graduation_radius=20,.graduation_thickness=4,.graduation_mark_circ=4,.graduation_mark_angle=30,
   .graduation_fg_clr=0xffffff,.graduation_fg_alpha=0,
   .saucer_thickness=3,.thick_saucer_circ=.75,.saucer_radius=30,.thin_saucer_circ=.75,
   .saucer_fg_clr=0xffffff,.saucer_fg_alpha=.3,
   .saucer_mark_fg_clr=0xffffff,.saucer_mark_fg_alpha=.5},
  {.name="memperc",.arg="/",.max_value=100,.x=80,.y=130,
   .cup_radius=12,.cup_wall_thickness=23,.total_angle=360,
   .cup_bg_clr=0xffffff,.cup_bg_alpha=0,.cup_fg_clr=0xffffff,.cup_fg_alpha=0,
   .handle_fg_clr=0xffffff,.handle_fg_alpha=0,.handle_length=40,.handle_circ=4,
   .xtxt=-15,.ytxt=-5,.txt_weight=0,.txt_size=7,
   .txt_fg_clr=0xffffff,.txt_fg_alpha=.8,.caption="RAM ",.caption2=" %",
   .graduation_radius=20,.graduation_thickness=3,.graduation_mark_circ=2,.graduation_mark_angle=36,
   .graduation_fg_clr=0xffffff,.graduation_fg_alpha=0,
   .saucer_thickness=3,.thick_saucer_circ=.85,.saucer_radius=25,.thin_saucer_circ=.85,
   .saucer_fg_clr=0xffffff,.saucer_fg_alpha=.3,
   .saucer_mark_fg_clr=0xffffff,.saucer_mark_fg_alpha=.5,.inner_saucer=1},
  {.name="swapperc",.arg="/",.max_value=100,.x=80,.y=130,
   .cup_radius=12,.cup_wall_thickness=27,.total_angle=360,
   .cup_bg_clr=0xffffff,.cup_bg_alpha=0,.cup_fg_clr=0xffffff,.cup_fg_alpha=0,
   .handle_fg_clr=0xffffff,.handle_fg_alpha=0,.handle_length=40,.handle_circ=4,
   .xtxt=-15,.ytxt=7,.txt_weight=0,.txt_size=7,
   .txt_fg_clr=0xffffff,.txt_fg_alpha=.8,.caption="Swp ",.caption2=" %",
   .graduation_radius=20,.graduation_thickness=4,.graduation_mark_circ=4,.graduation_mark_angle=30,
   .graduation_fg_clr=0xffffff,.graduation_fg_alpha=0,
   .saucer_thickness=3,.thick_saucer_circ=.85,.saucer_radius=30,.thin_saucer_circ=.85,
   .saucer_fg_clr=0xffffff,.saucer_fg_alpha=.3,
   .saucer_mark_fg_clr=0xffffff,.saucer_mark_fg_alpha=.5},
  {.name="fs_used_perc",.arg="/home",.max_value=100,.x=130,.y=180,
   .cup_radius=12,.cup_wall_thickness=27,.total_angle=360,
   .cup_bg_clr=0xffffff,.cup_bg_alpha=0,.cup_fg_clr=0xffffff,.cup_fg_alpha=0,
   .handle_fg_clr=0xffffff,.handle_fg_alpha=0,.handle_length=40,.handle_circ=4,
   .xtxt=-15,.ytxt=-5,.txt_weight=0,.txt_size=7,
   .txt_fg_clr=0xffffff,.txt_fg_alpha=.8,.caption="FS /: ",.caption2=" %",
   .graduation_radius=20,.graduation_thickness=3,.graduation_mark_circ=2,.graduation_mark_angle=36,
   .graduation_fg_clr=0xffffff,.graduation_fg_alpha=0,
   .saucer_thickness=3,.thick_saucer_circ=.85,.saucer_radius=25,.thin_saucer_circ=.85,
   .saucer_fg_clr=0xffffff,.saucer_fg_alpha=.3,
   .saucer_mark_fg_clr=0xffffff,.saucer_mark_fg_alpha=.5,.inner_saucer=1},
  {.name="fs_used_perc",.arg="/",.max_value=100,.x=130,.y=180,
   .cup_radius=12,.cup_wall_thickness=27,.total_angle=360,
   .cup_bg_clr=0xffffff,.cup_bg_alpha=0,.cup_fg_clr=0xffffff,.cup_fg_alpha=0,
   .handle_fg_clr=0xffffff,.handle_fg_alpha=0,.handle_length=40,.handle_circ=4,
   .xtxt=-15,.ytxt=7,.txt_weight=0,.txt_size=7,
   .txt_fg_clr=0xffffff,.txt_fg_alpha=.8,.caption="/Hm: ",.caption2=" %",
   .graduation_radius=20,.graduation_thickness=4,.graduation_mark_circ=4,.graduation_mark_angle=36,
   .graduation_fg_clr=0xffffff,.graduation_fg_alpha=0,
   .saucer_thickness=3,.thick_saucer_circ=.85,.saucer_radius=30,.thin_saucer_circ=.85,
   .saucer_fg_clr=0xffffff,.saucer_fg_alpha=.3,
   .saucer_mark_fg_clr=0xffffff,.saucer_mark_fg_alpha=.5},
};
#define N_CUPS (sizeof(cups)/sizeof(cups[0]))

/* ---------------- theming (matugen waybar-colors.css) ---------------- */
static int line_light = 1;
static int theme_mtime = 0;

static uint32_t darken(uint32_t c, double f) {
    int r=(int)(((c>>16)&0xff)*f), g=(int)(((c>>8)&0xff)*f), b=(int)((c&0xff)*f);
    return ((uint32_t)r<<16)|((uint32_t)g<<8)|(uint32_t)b;
}
static double luminance(uint32_t c) {
    return (0.2126*((c>>16)&0xff)+0.7152*((c>>8)&0xff)+0.0722*(c&0xff))/255.0;
}

/* mean brightness 0..1 of current wallpaper, via ImageMagick (once per change) */
static double wallpaper_luminance(void) {
    const char *home = getenv("HOME");
    if (!home) return -1.0;
    char path[1024];
    snprintf(path, sizeof path, "%s/.config/backgrounds/current-wallpaper", home);
    char cmd[2048];
    snprintf(cmd, sizeof cmd,
        "magick \"%s\" -resize 1x1 -format \"%%[fx:mean]\" info: 2>/dev/null",
        path);
    FILE *p = popen(cmd, "r");
    if (!p) return -1.0;
    char buf[64] = {0};
    if (fgets(buf, sizeof buf, p)) { pclose(p); return atof(buf); }
    pclose(p);
    return -1.0;
}

static void load_theme(void) {
    const char *home = getenv("HOME") ?: getenv("HOME");
    char path[1024];
    snprintf(path, sizeof path, "%s/.config/waybar/colors.css", home);
    struct stat st;
    if (stat(path, &st) != 0) return;
    if (st.st_mtime == theme_mtime) return;
    theme_mtime = (int)st.st_mtime;

    uint32_t text=0xffffff, accent=0x9FA8DA, accent2=0x80CBC4,
             accent3=0xFFC98A, err=0xEF9A9A, base=0x141218;
    FILE *f = fopen(path, "r");
    if (f) {
        char line[256]; char name[64]; unsigned h;
        while (fgets(line, sizeof line, f)) {
            if (sscanf(line, "@define-color %63s #%x", name, &h) == 2) {
                if      (!strcmp(name,"text")) text=h;
                else if (!strcmp(name,"blue")||!strcmp(name,"pink")||!strcmp(name,"mauve")) accent=h;
                else if (!strcmp(name,"sapphire")||!strcmp(name,"sky")) accent2=h;
                else if (!strcmp(name,"peach")||!strcmp(name,"yellow")) accent3=h;
                else if (!strcmp(name,"red")||!strcmp(name,"flamingo")) err=h;
                else if (!strcmp(name,"base")) base=h;
            }
        }
        fclose(f);
    }

    double wl = wallpaper_luminance();
    double base_lum = (wl >= 0) ? wl : luminance(base);
    line_light = base_lum < 0.5;
    uint32_t ring = text;
    if (!line_light) {
        ring    = darken(text, 0.15);
        accent  = darken(accent, 0.30);
        accent2 = darken(accent2, 0.30);
        accent3 = darken(accent3, 0.30);
        err     = darken(err, 0.30);
    }
    for (size_t i = 0; i < N_CUPS; i++) {
        const char *n = cups[i].name;
        uint32_t sub = (!strcmp(n,"cpu"))?accent:
                       (!strcmp(n,"freq_g"))?accent2:
                       (!strcmp(n,"memperc"))?accent3:
                       (!strcmp(n,"swapperc"))?err:accent;
        cups[i].handle_fg_clr = accent;
        cups[i].graduation_fg_clr = ring;
        cups[i].saucer_fg_clr = ring;
        cups[i].saucer_mark_fg_clr = accent;
        cups[i].cup_fg_clr = accent;
        cups[i].cup_bg_clr = ring;
        cups[i].txt_fg_clr = sub;
    }
}

/* ---------------- value readers ---------------- */
static long prev_total=0, prev_idle=0, prev_set=0;
static double cpu_pct(void) {
    FILE *f=fopen("/proc/stat","r"); char line[256];
    if(!f) return 0; fgets(line,sizeof line,f); fclose(f);
    long user,nice,sys,idle,iowait,irq,softirq,steal;
    sscanf(line,"cpu %ld %ld %ld %ld %ld %ld %ld %ld",&user,&nice,&sys,&idle,&iowait,&irq,&softirq,&steal);
    long total=user+nice+sys+idle+iowait+irq+softirq+steal;
    double p=0;
    if(prev_set){ long dt=total-prev_total, di=idle-prev_idle; if(dt>0) p=100.0*(1.0-(double)di/dt); }
    prev_total=total; prev_idle=idle; prev_set=1;
    return p<0?0:(p>100?100:p);
}
static double cpu_freq_g(void){
    FILE*f=fopen("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq","r");
    if(f){ long k; if(fscanf(f,"%ld",&k)==1){fclose(f);return k/1e6;} fclose(f);}
    f=fopen("/proc/cpuinfo","r");
    if(f){ char line[256];
        while(fgets(line,sizeof line,f))
            if(!strncmp(line,"cpu MHz",7)){ double mhz; sscanf(line,"cpu MHz : %lf",&mhz); fclose(f); return mhz/1000.0; }
        fclose(f); }
    return 0;
}
static long mem_total=0,mem_free=0;
static double mem_pct(void){
    FILE*f=fopen("/proc/meminfo","r"); char k[64]; long v; char u[16];
    long total=1,free=0,buf=0,cached=0,srec=0,swtot=0,swfree=0;
    while(f&&fscanf(f,"%63s %ld %15s",k,&v,u)==3){
        if(!strcmp(k,"MemTotal:")) total=v;
        else if(!strcmp(k,"MemFree:")) free=v;
        else if(!strcmp(k,"Buffers:")) buf=v;
        else if(!strcmp(k,"Cached:")) cached=v;
        else if(!strcmp(k,"SReclaimable:")) srec=v;
        else if(!strcmp(k,"SwapTotal:")) swtot=v;
        else if(!strcmp(k,"SwapFree:")) swfree=v;
    }
    if(f)fclose(f);
    return 100.0*(total-(free+buf+cached+srec))/total;
}
static double swap_pct(void){
    FILE*f=fopen("/proc/meminfo","r"); char k[64]; long v; char u[16];
    long swtot=0,swfree=0;
    while(f&&fscanf(f,"%63s %ld %15s",k,&v,u)==3){
        if(!strcmp(k,"SwapTotal:")) swtot=v;
        else if(!strcmp(k,"SwapFree:")) swfree=v;
    }
    if(f)fclose(f);
    return swtot?100.0*(swtot-swfree)/swtot:0;
}
static double fs_pct(const char *path){
    struct statvfs s; if(statvfs(path,&s)!=0) return 0;
    double total=s.f_blocks*s.f_frsize, used=(s.f_blocks-s.f_bfree)*s.f_frsize;
    return 100.0*used/total;
}

static double value_for(const Cup *d, struct tm *t) {
    const char *n=d->name;
    if(!strcmp(n,"time2")){ int hm=t->tm_hour%12; return hm + t->tm_min/60.0; }
    if(!strcmp(n,"time")){ char b[16]; strftime(b,sizeof b,d->arg,t); return atof(b); }
    if(!strcmp(n,"cpu")) return cpu_pct();
    if(!strcmp(n,"freq_g")) return cpu_freq_g();
    if(!strcmp(n,"memperc")) return mem_pct();
    if(!strcmp(n,"swapperc")) return swap_pct();
    if(!strcmp(n,"fs_used_perc")) return fs_pct(d->arg);
    return 0;
}

/* ---------------- drawing ---------------- */
static double DEFAULT(int z, double d){ return z? (double)z : d; }

static void halo_stroke(cairo_t *cr, double width, int light) {
    cairo_save(cr);
    cairo_set_line_width(cr, width + 6);
    if (light) cairo_set_source_rgba(cr, 0,0,0,0.28);
    else       cairo_set_source_rgba(cr, 1,1,1,0.32);
    cairo_stroke(cr);
    cairo_restore(cr);
}

static void draw_coffee_table(cairo_t *cr, const Cup *d, double value) {
    int maxv = d->max_value;
    double x = d->x ? d->x : SIZE/2.0;
    double y = d->y ? d->y : SIZE/2.0;
    double cup_r = DEFAULT(d->cup_radius, SIZE/4.0);
    double wall = DEFAULT(d->cup_wall_thickness, 20);
    double hlen = DEFAULT(d->handle_length, 20);
    double hcir = DEFAULT(d->handle_circ, 1);
    double start_a = d->cup_start_angle;
    double total = d->total_angle ? d->total_angle : 360;
    double sect = fabs(total)/maxv;
    double end_a = total + start_a;
    int neg = total < 0;

    uint32_t cup_bg= d->cup_bg_clr?d->cup_bg_clr:0xffffff, cbg_a=d->cup_bg_alpha;
    uint32_t cup_fg= d->cup_fg_clr?d->cup_fg_clr:0xffffff, cfg_a=d->cup_fg_alpha;
    uint32_t hfg  = d->handle_fg_clr?d->handle_fg_clr:0xffffff, hfg_a=d->handle_fg_alpha;

    double sau_r = DEFAULT(d->saucer_radius, SIZE/2.0);
    double tsau_a = 360;                 /* no cup overrides total_saucer_angle */
    double ssect = fabs(tsau_a)/maxv;
    double sau_t = DEFAULT(d->saucer_thickness,6);
    uint32_t sfg=d->saucer_fg_clr?d->saucer_fg_clr:0, sfg_a=d->saucer_fg_alpha;
    uint32_t smfg=d->saucer_mark_fg_clr?d->saucer_mark_fg_clr:0xffffff, smfg_a=d->saucer_mark_fg_alpha;
    double thk=d->thick_saucer_circ?d->thick_saucer_circ:0.9, thn=d->thin_saucer_circ?d->thin_saucer_circ:0.9;
    int inner=d->inner_saucer;

    double grad_r=DEFAULT(d->graduation_radius,SIZE/3.0), grad_t=DEFAULT(d->graduation_thickness,2);
    double gm_cir=DEFAULT(d->graduation_mark_circ,1), gm_a=d->graduation_mark_angle?d->graduation_mark_angle:total/10;
    uint32_t gfg=d->graduation_fg_clr?d->graduation_fg_clr:0xffffff, gfg_a=d->graduation_fg_alpha;

    double tsize=DEFAULT(d->txt_size,8);
    uint32_t tfg=d->txt_fg_clr?d->txt_fg_clr:0xffffff, tfg_a=d->txt_fg_alpha;
    double xtx=d->xtxt, ytx=d->ytxt;

    #define A2P(sa,ca) ((neg)? (((sa)-(ca))*(M_PI/180)-(M_PI/2)) : ((((ca)+(sa))*(M_PI/180))-(M_PI/2)))
    #define ARC(r,a1,a2) do{ if(neg) cairo_arc_negative(cr,x,y,r,a1,a2); else cairo_arc(cr,x,y,r,a1,a2);}while(0)

    if (cbg_a>0){ ARC(cup_r, A2P(start_a,0), A2P(start_a,end_a)); halo_stroke(cr,wall,line_light); ARC(cup_r, A2P(start_a,0), A2P(start_a,end_a)); cairo_set_line_width(cr,wall); cairo_set_source_rgba(cr,((cup_bg>>16)&0xff)/255.,((cup_bg>>8)&0xff)/255.,(cup_bg&0xff)/255.,cbg_a/255.0); cairo_stroke(cr); }
    if (cfg_a>0){ double fs=sect*value; ARC(cup_r,A2P(start_a,0),A2P(start_a,fs)); halo_stroke(cr,wall,line_light); ARC(cup_r,A2P(start_a,0),A2P(start_a,fs)); cairo_set_line_width(cr,wall); cairo_set_source_rgba(cr,((cup_fg>>16)&0xff)/255.,((cup_fg>>8)&0xff)/255.,(cup_fg&0xff)/255.,cfg_a/255.0); cairo_stroke(cr); }
    if (hfg_a>0){ double s=sect*value-hcir*0.5, e=sect*value+hcir*0.5; ARC(cup_r,A2P(start_a,s),A2P(start_a,e)); halo_stroke(cr,hlen,line_light); ARC(cup_r,A2P(start_a,s),A2P(start_a,e)); cairo_set_line_width(cr,hlen); cairo_set_source_rgba(cr,((hfg>>16)&0xff)/255.,((hfg>>8)&0xff)/255.,(hfg&0xff)/255.,hfg_a/255.0); cairo_stroke(cr); }
    if (sfg_a>0 && (thn>0||thk>0)){
        double j = value < maxv/2.0 ? value+maxv*tsau_a/720.0 : value-maxv*tsau_a/720.0;
        double ss=sect*j-value*sect*0.5*thk, se=sect*j+value*sect*0.5*thk;
        ARC(sau_r,A2P(start_a,ss),A2P(start_a,se)); cairo_set_line_width(cr,sau_t); cairo_set_source_rgba(cr,((sfg>>16)&0xff)/255.,((sfg>>8)&0xff)/255.,(sfg&0xff)/255.,sfg_a/255.0); cairo_stroke(cr);
        double rt= inner? (sau_r-0.5)+(0.5*sau_t) : (sau_r+0.5)-(0.5*sau_t);
        double ts=sect*j-maxv*0.5*sect*thn, te=sect*j+maxv*0.5*sect*thn;
        ARC(rt,A2P(start_a,ts),A2P(start_a,te)); cairo_set_line_width(cr,1); cairo_set_source_rgba(cr,((sfg>>16)&0xff)/255.,((sfg>>8)&0xff)/255.,(sfg&0xff)/255.,sfg_a/255.0); cairo_stroke(cr);
    }
    if (smfg_a>0){ double s=sect*value-hcir*0.5, e=sect*value+hcir*0.5; ARC(sau_r,A2P(start_a,s),A2P(start_a,e)); cairo_set_line_width(cr,sau_t); cairo_set_source_rgba(cr,((smfg>>16)&0xff)/255.,((smfg>>8)&0xff)/255.,(smfg&0xff)/255.,smfg_a/255.0); cairo_stroke(cr); }
    if (grad_r>0 && grad_t>0 && gm_a>0){
        int n=(int)((fabs(total)+1)/gm_a); int i;
        for(i=0;i<n;i++){ double s=gm_a*i-gm_cir*0.5, e=gm_a*i+gm_cir*0.5; ARC(grad_r,A2P(start_a,s),A2P(start_a,e)); cairo_set_line_width(cr,grad_t); cairo_set_source_rgba(cr,((gfg>>16)&0xff)/255.,((gfg>>8)&0xff)/255.,(gfg&0xff)/255.,gfg_a/255.0); cairo_stroke(cr); }
    }
    if (tfg_a>0){
        cairo_select_font_face(cr,FONT,CAIRO_FONT_SLANT_NORMAL,d->txt_weight);
        cairo_set_font_size(cr,tsize);
        cairo_set_source_rgba(cr,((tfg>>16)&0xff)/255.,((tfg>>8)&0xff)/255.,(tfg&0xff)/255.,tfg_a/255.0);
        char buf[64];
        char vfmt[32]; snprintf(vfmt,sizeof vfmt,"%s%%d%s",d->caption,d->caption2);
        snprintf(buf,sizeof buf,vfmt,(int)lround(value));
        cairo_move_to(cr,x+xtx,y+ytx);
        cairo_show_text(cr,buf);
        cairo_stroke(cr);
    }
    #undef A2P
    #undef ARC
}

static void on_draw(GtkDrawingArea *da, cairo_t *cr, int w, int h, gpointer data) {
    load_theme();
    cairo_save(cr);
    cairo_scale(cr, SCALE, SCALE);
    cairo_set_antialias(cr, CAIRO_ANTIALIAS_SUBPIXEL);
    time_t now=time(NULL); struct tm tmv; localtime_r(&now,&tmv);
    for (size_t i=0;i<N_CUPS;i++) {
        double v = value_for(&cups[i], &tmv);
        draw_coffee_table(cr, &cups[i], v);
    }
    cairo_restore(cr);
}

static gboolean tick(gpointer data){ gtk_widget_queue_draw(GTK_WIDGET(data)); return G_SOURCE_CONTINUE; }

static void activate(GtkApplication *app, gpointer data) {
    GtkWidget *win = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(win), "Revolutionary Clock");
    gtk_window_set_default_size(GTK_WINDOW(win), SIZE, SIZE);
    gtk_window_set_resizable(GTK_WINDOW(win), FALSE);
    gtk_window_set_decorated(GTK_WINDOW(win), FALSE);
    gtk_window_set_application(GTK_WINDOW(win), app);

    gtk_layer_init_for_window(GTK_WINDOW(win));
    gtk_layer_set_layer(GTK_WINDOW(win), GTK_LAYER_SHELL_LAYER_BOTTOM);
    gtk_layer_set_anchor(GTK_WINDOW(win), GTK_LAYER_SHELL_EDGE_LEFT, TRUE);
    gtk_layer_set_anchor(GTK_WINDOW(win), GTK_LAYER_SHELL_EDGE_TOP, TRUE);
    gtk_layer_set_margin(GTK_WINDOW(win), GTK_LAYER_SHELL_EDGE_LEFT, 24);
    gtk_layer_set_margin(GTK_WINDOW(win), GTK_LAYER_SHELL_EDGE_TOP, 48);
    gtk_layer_set_exclusive_zone(GTK_WINDOW(win), -1);
    gtk_layer_set_keyboard_mode(GTK_WINDOW(win), GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);

    GtkCssProvider *css = gtk_css_provider_new();
    gtk_css_provider_load_from_string(css, "window { background: transparent; }");
    gtk_style_context_add_provider_for_display(gdk_display_get_default(),
        GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);

    GtkWidget *da = gtk_drawing_area_new();
    gtk_widget_set_size_request(da, SIZE, SIZE);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(da), on_draw, NULL, NULL);
    gtk_window_set_child(GTK_WINDOW(win), da);
    gtk_widget_set_visible(win, TRUE);

    g_timeout_add_seconds(1, tick, da);
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("com.revolutionary.clock",
                                              G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
