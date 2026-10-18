#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <vulkan/vulkan.h>
#define EXP __attribute__((visibility("default")))
static void *h; static PFN_vkGetInstanceProcAddr r_gipa; static PFN_vkGetDeviceProcAddr r_gdpa;
static void init(void){ if(h)return;
  char cand[4][2048]; int n=0; const char *e=getenv("MAGE_REAL_MOLTENVK");
  if(e&&*e) snprintf(cand[n++],2048,"%s",e);
  Dl_info di; if(dladdr((void*)init,&di)&&di.dli_fname){ char d[2048]; snprintf(d,2048,"%s",di.dli_fname); char *sl=strrchr(d,'/'); if(sl)*sl=0;
    snprintf(cand[n++],2048,"%s/libMoltenVK.dylib",d); snprintf(cand[n++],2048,"%s/../../libMoltenVK.dylib",d); }
  snprintf(cand[n++],2048,"libMoltenVK.dylib");
  for(int i=0;i<n&&!h;i++){ h=dlopen(cand[i],RTLD_NOW|RTLD_LOCAL); if(h)fprintf(stderr,"vkshim: loaded %s\n",cand[i]); }
  if(!h){fprintf(stderr,"vkshim: no MoltenVK found: %s\n",dlerror());return;}
  r_gipa=(PFN_vkGetInstanceProcAddr)dlsym(h,"vkGetInstanceProcAddr"); r_gdpa=(PFN_vkGetDeviceProcAddr)dlsym(h,"vkGetDeviceProcAddr");}
static VkResult VKAPI_CALL nop_name(VkDevice d,const VkDebugUtilsObjectNameInfoEXT *i){return VK_SUCCESS;}
static VkResult VKAPI_CALL nop_tag(VkDevice d,const VkDebugUtilsObjectTagInfoEXT *i){return VK_SUCCESS;}
static void VKAPI_CALL nop_cmd(VkCommandBuffer c,const VkDebugUtilsLabelEXT *l){}
static void VKAPI_CALL nop_cmdend(VkCommandBuffer c){}
static void VKAPI_CALL nop_q(VkQueue q,const VkDebugUtilsLabelEXT *l){}
static void VKAPI_CALL nop_qend(VkQueue q){}
static PFN_vkVoidFunction filt(const char *n){
  if(!strcmp(n,"vkSetDebugUtilsObjectNameEXT"))return (PFN_vkVoidFunction)nop_name;
  if(!strcmp(n,"vkSetDebugUtilsObjectTagEXT"))return (PFN_vkVoidFunction)nop_tag;
  if(!strcmp(n,"vkCmdBeginDebugUtilsLabelEXT")||!strcmp(n,"vkCmdInsertDebugUtilsLabelEXT"))return (PFN_vkVoidFunction)nop_cmd;
  if(!strcmp(n,"vkCmdEndDebugUtilsLabelEXT"))return (PFN_vkVoidFunction)nop_cmdend;
  if(!strcmp(n,"vkQueueBeginDebugUtilsLabelEXT")||!strcmp(n,"vkQueueInsertDebugUtilsLabelEXT"))return (PFN_vkVoidFunction)nop_q;
  if(!strcmp(n,"vkQueueEndDebugUtilsLabelEXT"))return (PFN_vkVoidFunction)nop_qend;
  return 0;}
EXP PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice d,const char *n){init();PFN_vkVoidFunction f=filt(n);if(f)return f;
  if(!strcmp(n,"vkGetDeviceProcAddr"))return (PFN_vkVoidFunction)vkGetDeviceProcAddr; return r_gdpa(d,n);}
EXP PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance i,const char *n){init();PFN_vkVoidFunction f=filt(n);if(f)return f;
  if(!strcmp(n,"vkGetInstanceProcAddr"))return (PFN_vkVoidFunction)vkGetInstanceProcAddr;
  if(!strcmp(n,"vkGetDeviceProcAddr"))return (PFN_vkVoidFunction)vkGetDeviceProcAddr; return r_gipa(i,n);}
EXP VkResult VKAPI_CALL vkCreateInstance(const VkInstanceCreateInfo *c,const VkAllocationCallbacks *a,VkInstance *o){init();return ((PFN_vkCreateInstance)r_gipa(0,"vkCreateInstance"))(c,a,o);}
EXP VkResult VKAPI_CALL vkEnumerateInstanceExtensionProperties(const char *l,uint32_t *n,VkExtensionProperties *p){init();return ((PFN_vkEnumerateInstanceExtensionProperties)r_gipa(0,"vkEnumerateInstanceExtensionProperties"))(l,n,p);}
EXP VkResult VKAPI_CALL vkEnumerateInstanceVersion(uint32_t *v){init();return ((PFN_vkEnumerateInstanceVersion)r_gipa(0,"vkEnumerateInstanceVersion"))(v);}
EXP VkResult VKAPI_CALL vkEnumerateInstanceLayerProperties(uint32_t *n,VkLayerProperties *p){init();return ((PFN_vkEnumerateInstanceLayerProperties)r_gipa(0,"vkEnumerateInstanceLayerProperties"))(n,p);}
