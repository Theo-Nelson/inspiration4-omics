#!/usr/bin/env Rscript
args = commandArgs(trailingOnly=TRUE)

library(tidyverse)
library(lme4)
library(broom)
library(broom.mixed)
library(reshape2)
library(lmerTest)

dtype=args[[1]]
org=args[[2]]
taxlevel=args[[3]]
filepath=args[[4]]
algorithm=args[[5]]
cutoffs=args[[6]]
dataframedescr=args[[7]]
outname = paste(org,dtype,taxlevel,algorithm,cutoffs,dataframedescr,sep='_')

# load metadata
meta = read.csv('i4_swab_metadata.csv') %>% mutate(location = if_else(Crew.ID == 'Capsule','Capsule',Body.Location))
meta$SeqID = gsub('ELMB_','',meta$SeqID)
meta$SeqID = gsub('SW_','',meta$SeqID)
meta$Timepoint_Recode = factor(meta$Timepoint)
levels(meta$Timepoint_Recode) = c(NA,'PRE-LAUNCH','POST-LAUNCH','PRE-LAUNCH','MID-FLIGHT','MID-FLIGHT','POST-LAUNCH','POST-LAUNCH','PRE-LAUNCH')

meta = meta %>% distinct %>% mutate(Timepoint_Recode2 = if_else(as.character(Timepoint_Recode) == 'MID-FLIGHT',Timepoint,as.character(Timepoint_Recode)))
meta$Timepoint_Recode2 = factor(meta$Timepoint_Recode2,levels = c('PRE-LAUNCH','Flight 1','Flight 2','POST-LAUNCH'))
meta$Timepoint = factor(meta$Timepoint,levels=c('21-Jun','21-Aug','Sept Pre-Launch','Flight 1','Flight 2','Sept Post-Return','November','21-Dec',NA))
meta$Timepoint_Numeric = as.numeric(meta$Timepoint)

sanitize_sample_names <- function(data){
  temp = data %>% t %>% as.data.frame %>% rownames_to_column('temp') %>% mutate(namelengths = nchar(temp))
  temp = temp %>% mutate(temp = if_else(namelengths>=3 & str_sub(temp,nchar(temp),nchar(temp))=='D',str_sub(temp,1,nchar(temp)-1),temp))
  return(temp %>% column_to_rownames('temp') %>% select(-namelengths) %>% t %>% data.frame(check.names=F))
}

oac = meta %>% filter(location == 'Open Air Control' | Body.Location == 'Control Swab (0)' | Body.Location == 'Swab Water')
oac = oac %>% select(SeqID) %>% unlist %>% unname 

remove_potential_contamination <- function(data,oac){
  fpg = data %>% select(any_of(oac)) %>% rownames_to_column('microbe') %>% melt 
  todrop = fpg %>% filter(value>quantile(fpg$value,na.rm=T,.75)) %>% select(microbe) %>% unlist %>% unname %>% unique
  data = data[setdiff(rownames(data),todrop),]
  return(data)
}

# load abundance tables
if(dtype == 'dna' &  algorithm=='kraken2'){
  print('Loading kraken2 WGS data')
  kraken_metag = read.delim(filepath,check.names=F)
  kraken_metag = kraken_metag %>% select(name,all_of(grep('bracken_frac',colnames(.)))) 
  colnames(kraken_metag) = map(colnames(kraken_metag),function(x) gsub('.qc.bracken_frac','',x))
  kraken_metag = kraken_metag%>% as.data.frame%>% column_to_rownames('name') 
  abdata = remove_potential_contamination(sanitize_sample_names(kraken_metag),oac)
}

if(dtype == 'rna' & algorithm=='kraken2'){
  print('Loading kraken2 MTX data')
  kraken_metat = read.delim(filepath,check.names=F)
  kraken_metat = kraken_metat %>% select(name,all_of(grep('bracken_frac',colnames(.)))) 
  colnames(kraken_metat) = map(colnames(kraken_metat),function(x) gsub('.qc.bracken_frac','',x))
  kraken_metat = kraken_metat%>% as.data.frame%>% column_to_rownames('name')
  abdata = remove_potential_contamination(sanitize_sample_names(kraken_metat),oac)
}

if(dtype == 'dna' & org=='bacterial' & algorithm=='xtree'){
  print('Loading bacterial WGS data')
  wgs_bacterial = read.csv(filepath,sep='\t',check.names=F)
  abdata = remove_potential_contamination(sanitize_sample_names(wgs_bacterial),oac)
}

if(dtype == 'dna' & org=='viral' & algorithm=='xtree'){
  print('Loading viral WGS data')
  wgs_viral = read.csv(filepath,sep='\t',check.names=F)
  abdata = remove_potential_contamination(sanitize_sample_names(wgs_viral),oac)
}

if(dtype == 'rna' & org=='bacterial' & algorithm=='xtree'){
  print('Loading bacterial MTX data')
  abdata = read.csv(filepath,sep='\t',check.names=F)
  colnames(abdata) = gsub('Sample_','',colnames(abdata))
  abdata = remove_potential_contamination(abdata,oac)
}

if(dtype == 'rna' & org=='viral' & algorithm=='xtree'){
  print('Loading viral MTX data')
  abdata = read.csv(filepath,sep='\t',check.names=F)
  colnames(abdata) = gsub('Sample_','',colnames(abdata))
  abdata = remove_potential_contamination(abdata,oac)
}

# run the regressions

metasub = meta %>% filter(Body.Location != "Swab Water",location!='Capsule',Body.Location != 'Open Air Control', Body.Location != "Deltoid - Pre-Biospy", !is.na(Body.Location))

metasub$Timepoint_Recode = factor(metasub$Timepoint_Recode,levels = c('PRE-LAUNCH','MID-FLIGHT','POST-LAUNCH'))
metasub = metasub %>% mutate(Timepoint = if_else(Timepoint == 'Flight 1' | Timepoint == 'Flight 2','Mid-Flight',as.character(Timepoint)))
metasub$Timepoint = factor(metasub$Timepoint,levels=c('21-Jun','21-Aug','Sept Pre-Launch','Mid-Flight','Sept Post-Return','November','21-Dec',NA))
metasub$Timepoint_Recode = factor(metasub$Timepoint_Recode,levels=c('MID-FLIGHT','PRE-LAUNCH','POST-LAUNCH'))
metasub = metasub %>% mutate(isoral = if_else(Body.Location == 'Oral',1,0))
metasub = metasub %>% mutate(isnasal = if_else(Body.Location == 'Nasal',1,0))
metasub = metasub %>% mutate(isskin = if_else(Body.Location != 'Oral' & Body.Location != 'Nasal',1,0))
metasub = metasub %>% mutate(Armpit = if_else(Body.Location == 'Armpit',1,0))
metasub = metasub %>% mutate(web = if_else(Body.Location == 'Toe Web Space',1,0))
metasub = metasub %>% mutate(nape = if_else(Body.Location == 'Nape of Neck',1,0))
metasub = metasub %>% mutate(postauric = if_else(Body.Location == 'Post-Auricular',1,0))
metasub = metasub %>% mutate(fore = if_else(Body.Location == 'Forearm',1,0))
metasub = metasub %>% mutate(bb = if_else(Body.Location == 'Belly Button',1,0))
metasub = metasub %>% mutate(gc = if_else(Body.Location == 'Gluteal Crease',1,0))
metasub = metasub %>% mutate(nasal = if_else(Body.Location == 'Nasal',1,0))
metasub = metasub %>% mutate(Tzone = if_else(Body.Location == 'T-Zone',1,0))
metasub = metasub %>% mutate(Oral = if_else(Body.Location == 'Oral',1,0))

microbesofinterest = rownames(abdata)
minval = min(abdata[abdata>0])

abdata_t = abdata %>% t %>% data.frame(check.names=F) %>% rownames_to_column('SeqID')

abdata_meta = inner_join(abdata_t,metasub,by='SeqID')

regression_output_overall = list()
regression_output_skin = list()
regression_output_skinseparates = list()
regression_output_nasal = list()
regression_output_oral = list()
for(m in microbesofinterest){
 # regression_output_overall[[m]] = try(lmer(data = abdata_meta,log(abdata_meta[,m] + minval) ~ Timepoint_Recode  + (1|Crew.ID)) %>% tidy %>% mutate(yvar = m) %>% filter(term!='(Intercept)'),silent=T)
  regression_output_skin[[m]] = try(lmer(data = abdata_meta,log(abdata_meta[,m] + minval) ~ Timepoint_Recode*isskin  + (1|Crew.ID)) %>% tidy %>% mutate(yvar = m) %>% filter(term!='(Intercept)'),silent=T)
  regression_output_nasal[[m]] = try(lmer(data = abdata_meta,log(abdata_meta[,m] + minval) ~ Timepoint_Recode*isnasal + (1|Crew.ID)) %>% tidy %>% mutate(yvar = m) %>% filter(term!='(Intercept)'),silent=T)
  regression_output_oral[[m]] = try(lmer(data = abdata_meta,log(abdata_meta[,m] + minval) ~ Timepoint_Recode*isoral + (1|Crew.ID)) %>% tidy %>% mutate(yvar = m) %>% filter(term!='(Intercept)'),silent=T)
  regression_output_skinseparates[[m]] = try(lmer(data = abdata_meta,log(abdata_meta[,m] + minval) ~ Timepoint_Recode*Armpit +Timepoint_Recode*web + Timepoint_Recode*nape + Timepoint_Recode*postauric + Timepoint_Recode*fore + Timepoint_Recode*bb + Timepoint_Recode*gc + Timepoint_Recode*Tzone + (1|Crew.ID)) %>% tidy %>% mutate(yvar = m) %>% filter(term!='(Intercept)'),silent=T)
}

#regression_output_overall = bind_rows(regression_output_overall)
#regression_output_overall = regression_output_overall %>% mutate(BH_adjusted = p.adjust(p.value,method='BH'),BY_adjusted = p.adjust(p.value,method='BY'),BONFERRONI_adjusted = p.adjust(p.value,method='bonferroni'))
#write.table(regression_output_overall,paste('regression_output_overall_',outname,'.tsv',sep=''),quote=F,sep='\t')

regression_output_skin = bind_rows(regression_output_skin)
regression_output_skin = regression_output_skin %>% mutate(BH_adjusted = p.adjust(p.value,method='BH'),BY_adjusted = p.adjust(p.value,method='BY'),BONFERRONI_adjusted = p.adjust(p.value,method='bonferroni'))
write.table(regression_output_skin,paste('regression_output_skin_',outname,'.tsv',sep=''),quote=F,sep='\t')

regression_output_nasal = bind_rows(regression_output_nasal)
regression_output_nasal = regression_output_nasal %>% mutate(BH_adjusted = p.adjust(p.value,method='BH'),BY_adjusted = p.adjust(p.value,method='BY'),BONFERRONI_adjusted = p.adjust(p.value,method='bonferroni'))
write.table(regression_output_nasal,paste('regression_output_nasal_',outname,'.tsv',sep=''),quote=F,sep='\t')

regression_output_oral = bind_rows(regression_output_oral)
regression_output_oral = regression_output_oral %>% mutate(BH_adjusted = p.adjust(p.value,method='BH'),BY_adjusted = p.adjust(p.value,method='BY'),BONFERRONI_adjusted = p.adjust(p.value,method='bonferroni'))
write.table(regression_output_oral,paste('regression_output_oral_',outname,'.tsv',sep=''),quote=F,sep='\t')

regression_output_skinseparates = bind_rows(regression_output_skinseparates)
regression_output_skinseparates = regression_output_skinseparates  %>% mutate(BH_adjusted = p.adjust(p.value,method='BH'),BY_adjusted = p.adjust(p.value,method='BY'),BONFERRONI_adjusted = p.adjust(p.value,method='bonferroni'))
write.table(regression_output_skinseparates,paste('regression_output_skin_site_by_site_',outname,'.tsv',sep=''),quote=F,sep='\t')



