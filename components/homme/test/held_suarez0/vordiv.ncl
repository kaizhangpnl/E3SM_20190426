load "$NCARG_ROOT/lib/ncarg/nclscripts/csm/gsn_code.ncl"
load "$NCARG_ROOT/lib/ncarg/nclscripts/csm/gsn_csm.ncl"
load "$NCARG_ROOT/lib/ncarg/nclscripts/csm/contributed.ncl"

begin
setvalues NhlGetWorkspaceObjectId() 
   "wsMaximumSize" : 50000000
end setvalues 


;  output_format = "ncgm"
  output_format = "pdf"
;  output_format = "X11"

  fave = addfile("hsmapave.nc","r")
  f = addfile("movies/held_suarez01.nc","r")


  
  wks = gsn_open_wks(output_format,"vordiv")
  nlat = dimsizes(f->lat)
  nlon = dimsizes(f->lon)
  nlev = dimsizes(f->lev)
  ntimes = dimsizes(f->time)
  
  print ("ntimes="+ntimes+" nlev="+nlev+" nlat x nlon "+nlat+"x"+nlon)
  
  
; http://ngwww.ucar.edu/ncl/coltable.html
  gsn_define_colormap(wks,"BlAqGrYeOrReVi200")
  
  res=True
  res@cnLevelSelectionMode = "ManualLevels"
  res@gsnMaximize         = True         ; Maximize size of plot in frame
  res@gsnPaperOrientation = "portrait"
  res@gsnSpreadColors     = True         ; Use full colormap, but start
;  res@gsnSpreadColorStart = 50           ; at color index 24.
    
    
  res@cnFillOn            = True         ; Turn on contour fill
;   res@cnFillMode          = "AreaFill"   ; Style of fill. You can also
  res@cnFillMode          = "RasterFill"   ; Style of fill. You can also
;    res@cnFillMode          = "CellFill"   ; Style of fill. You can also
                                ; use "CellFill" and "RasterFill"
  res@cnLinesOn           = False     ; Turn off contour lines
  res@cnLineLabelsOn      = False        ; Turn off contour line labels
  res@lbLabelAutoStride   = True         ; Clean up labelbar labels.
  res@lbBoxLinesOn        = False        ; Turn of labelbar box lines.
  
  res@mpOutlineOn          = True
  res@mpFillOn             = False
;    res@mpShapeMode          = "FreeAspect"





  do projection=0,2

    if ( projection .eq. 0) then    
       res@mpMinLatF = -90.
       res@mpMaxLatF = 90.
       res@mpMinLonF = -180.
       res@mpMaxLonF = 180.
    end if
    if ( projection .eq. 1) then    
       res@mpMinLatF = -40.
       res@mpMaxLatF = 15.
       res@mpMinLonF = -100.
       res@mpMaxLonF =  -40.
    end if
    if ( projection .eq. 2) then    
       res@mpMinLatF = 0.
       res@mpMaxLatF = 60.
       res@mpMinLonF = 50.
       res@mpMaxLonF = 110.
    end if

    k=21
    eta = (f->hyam(k)+f->hybm(k))
    eta_mb = 1000*eta
    print("model level:  k="+k+" eta_mb="+eta_mb)

;  climatology
    zrange=.00004  ; means (level 23), no topo
    res@cnMinLevelValF = -zrange
    res@cnMaxLevelValF =  zrange
    res@cnLevelSpacingF = zrange/20
    field = fave->zeta(k,:,:)
    print("zeta climo min/max ="+min(field)+" "+max(field))
    print("levels: [" + res@cnMinLevelValF +","+res@cnMaxLevelValF +"] spacing="+res@cnLevelSpacingF)
    res@tiMainString="Climatology "+sprintf("%3.0f",eta_mb)+"hPa"
    contour = gsn_csm_contour_map(wks,field,res)   
    

;  snapshots
    zrange=.00015  ; instantaneous
    res@cnMinLevelValF = -zrange
    res@cnMaxLevelValF =  zrange
    res@cnLevelSpacingF = zrange/20
    field = f->zeta(0,k,:,:)
    print("zeta snapshot min/max ="+min(field)+" "+max(field))
    print("levels: [" + res@cnMinLevelValF +","+res@cnMaxLevelValF +"] spacing="+res@cnLevelSpacingF)
    res@tiMainString=sprintf("%3.0f",eta_mb)+"hPa"
    contour = gsn_csm_contour_map(wks,field,res)   

;  climatology
    k=21
    zrange=.00004  ; means (level 23), no topo
    res@cnMinLevelValF = -zrange
    res@cnMaxLevelValF =  zrange
    res@cnLevelSpacingF = zrange/20
    field = fave->div(k,:,:)
    field@long_name = "Divergence"
    print("div climo min/max ="+min(field)+" "+max(field))
    print("levels: [" + res@cnMinLevelValF +","+res@cnMaxLevelValF +"] spacing="+res@cnLevelSpacingF)
    res@tiMainString="Climatology "+sprintf("%3.0f",eta_mb)+"hPa"
    contour = gsn_csm_contour_map(wks,field,res)   
    

;  snapshots
    k=21
    zrange=.0001  ; instantaneous
    res@cnMinLevelValF = -zrange
    res@cnMaxLevelValF =  zrange
    res@cnLevelSpacingF = zrange/20
    field = f->div(0,k,:,:)
    field@long_name = "Divergence"
    print("div snapshot min/max ="+min(field)+" "+max(field))
    print("levels: [" + res@cnMinLevelValF +","+res@cnMaxLevelValF +"] spacing="+res@cnLevelSpacingF)
    res@tiMainString=sprintf("%3.0f",eta_mb)+"hPa"
    contour = gsn_csm_contour_map(wks,field,res)   

  end do
delete(wks)
end


