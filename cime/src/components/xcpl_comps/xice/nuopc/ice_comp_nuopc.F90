module ice_comp_nuopc

  !----------------------------------------------------------------------------
  ! This is the NUOPC cap for XICE
  !----------------------------------------------------------------------------

  use ESMF
  use NUOPC                 , only : NUOPC_CompDerive, NUOPC_CompSetEntryPoint, NUOPC_CompSpecialize
  use NUOPC                 , only : NUOPC_CompAttributeGet, NUOPC_Advertise
  use NUOPC_Model           , only : model_routine_SS        => SetServices
  use NUOPC_Model           , only : model_label_Advance     => label_Advance
  use NUOPC_Model           , only : model_label_SetRunClock => label_SetRunClock
  use NUOPC_Model           , only : model_label_Finalize    => label_Finalize
  use NUOPC_Model           , only : NUOPC_ModelGet
  use med_constants_mod     , only : R8, CL, CS
  use med_constants_mod     , only : shr_file_getlogunit, shr_file_setlogunit
  use shr_nuopc_scalars_mod , only : flds_scalar_name
  use shr_nuopc_scalars_mod , only : flds_scalar_num
  use shr_nuopc_scalars_mod , only : flds_scalar_index_nx
  use shr_nuopc_scalars_mod , only : flds_scalar_index_ny
  use shr_nuopc_methods_mod , only : shr_nuopc_methods_Clock_TimePrint
  use shr_nuopc_methods_mod , only : shr_nuopc_methods_State_SetScalar
  use shr_nuopc_methods_mod , only : shr_nuopc_methods_State_Diagnose
  use shr_nuopc_methods_mod , only : shr_nuopc_methods_State_GetFldPtr
  use shr_nuopc_methods_mod , only : chkerr => shr_nuopc_methods_ChkErr 
  use dead_nuopc_mod        , only : dead_grid_lat, dead_grid_lon, dead_grid_index
  use dead_nuopc_mod        , only : dead_init_nuopc, dead_final_nuopc, dead_meshinit
  use dead_nuopc_mod        , only : fld_list_add, fld_list_realize, fldsMax, fld_list_type
  use dead_nuopc_mod        , only : ModelInitPhase, ModelSetRunClock
  use med_constants_mod     , only : dbug => med_constants_dbug_flag

  implicit none
  private ! except

  public :: SetServices

  !--------------------------------------------------------------------------
  ! Private module data
  !--------------------------------------------------------------------------

  integer                    :: fldsToIce_num = 0
  integer                    :: fldsFrIce_num = 0
  type (fld_list_type)       :: fldsToIce(fldsMax)
  type (fld_list_type)       :: fldsFrIce(fldsMax)
  integer, parameter         :: gridTofieldMap = 2 ! ungridded dimension is innermost

  real(r8), pointer          :: gbuf(:,:)            ! model info
  real(r8), pointer          :: lat(:)
  real(r8), pointer          :: lon(:)
  integer , allocatable      :: gindex(:)
  integer                    :: nxg                  ! global dim i-direction
  integer                    :: nyg                  ! global dim j-direction
  integer                    :: my_task              ! my task in mpi communicator mpicom
  integer                    :: inst_index           ! number of current instance (ie. 1)
  character(len=16)          :: inst_name            ! fullname of current instance (ie. "ice_0001")
  character(len=16)          :: inst_suffix = ""     ! char string associated with instance (ie. "_0001" or "")
  integer                    :: logunit              ! logging unit number
  integer    ,parameter      :: master_task=0        ! task number of master task
  logical                    :: mastertask
  character(*),parameter     :: modName =  "(xice_comp_nuopc)"
  character(*),parameter     :: u_FILE_u = &
       __FILE__

  !===============================================================================
  contains
  !===============================================================================
  subroutine SetServices(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc
    character(len=*),parameter  :: subname=trim(modName)//':(SetServices) '

    rc = ESMF_SUCCESS
    call ESMF_LogWrite(subname//' called', ESMF_LOGMSG_INFO, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    ! the NUOPC gcomp component will register the generic methods
    call NUOPC_CompDerive(gcomp, model_routine_SS, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    ! switching to IPD versions
    call ESMF_GridCompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
         userRoutine=ModelInitPhase, phase=0, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    ! set entry point for methods that require specific implementation
    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, phaseLabelList=(/"IPDv01p1"/), &
         userRoutine=InitializeAdvertise, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, phaseLabelList=(/"IPDv01p3"/), &
         userRoutine=InitializeRealize, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    ! attach specializing method(s)
    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_Advance, specRoutine=ModelAdvance, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    call ESMF_MethodRemove(gcomp, label=model_label_SetRunClock, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_SetRunClock, specRoutine=ModelSetRunClock, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_Finalize, specRoutine=ModelFinalize, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    call ESMF_LogWrite(subname//' done', ESMF_LOGMSG_INFO, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

  end subroutine SetServices


  !===============================================================================

  subroutine InitializeAdvertise(gcomp, importState, exportState, clock, rc)

    use shr_nuopc_utils_mod, only : shr_nuopc_set_component_logging
    use shr_nuopc_utils_mod, only : shr_nuopc_get_component_instance

    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    ! local variables
    type(ESMF_VM)      :: vm
    character(CL)      :: cvalue
    character(CS)      :: stdname
    integer            :: n
    integer            :: lsize       ! local array size
    integer            :: shrlogunit  ! original log unit
    character(len=*),parameter :: subname=trim(modName)//':(InitializeAdvertise) '
    !-------------------------------------------------------------------------------

    rc = ESMF_SUCCESS
    if (dbug > 5) call ESMF_LogWrite(subname//' called', ESMF_LOGMSG_INFO, rc=rc)

    call ESMF_GridCompGet(gcomp, vm=vm, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    call ESMF_VMGet(vm, localpet=my_task, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    mastertask = my_task == master_task

    !----------------------------------------------------------------------------
    ! determine instance information
    !----------------------------------------------------------------------------

    call shr_nuopc_get_component_instance(gcomp, inst_suffix, inst_index)
    inst_name = "ICE"//trim(inst_suffix)

    !----------------------------------------------------------------------------
    ! set logunit and set shr logging to my log file
    !----------------------------------------------------------------------------

    call shr_nuopc_set_component_logging(gcomp, my_task==master_task, logunit, shrlogunit)

    !----------------------------------------------------------------------------
    ! Initialize xice
    !----------------------------------------------------------------------------

    call dead_init_nuopc('ice', inst_suffix, logunit, lsize, gbuf, nxg, nyg)

    allocate(gindex(lsize))
    allocate(lon(lsize))
    allocate(lat(lsize))

    gindex(:) = gbuf(:,dead_grid_index)
    lat(:)    = gbuf(:,dead_grid_lat)
    lon(:)    = gbuf(:,dead_grid_lon)

    !--------------------------------
    ! advertise import and export fields
    !--------------------------------

    if (nxg /= 0 .and. nyg /= 0) then

       call fld_list_add(fldsFrIce_num, fldsFrIce, trim(flds_scalar_name))
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Si_imask'      )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Si_ifrac'      )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Si_t'          )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Si_tref'       )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Si_qref'       )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Si_snowh'      )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Si_u10'        )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Si_avsdr'      )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Si_anidr'      )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Si_avsdf'      )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Si_anidf'      )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Faii_taux'     )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Faii_tauy'     )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Faii_lat'      )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Faii_sen'      )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Faii_lwup'     )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Faii_evap'     )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Faii_swnet'    )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Fioi_melth'    )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Fioi_swpen'    )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Fioi_meltw'    )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Fioi_salt'     )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Fioi_taux'     )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Fioi_tauy'     )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Fioi_bcpho'    )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Fioi_bcphi'    )
       call fld_list_add(fldsFrIce_num, fldsFrIce, 'Fioi_flxdst'   )

       call fld_list_add(fldsToIce_num, fldsToIce, trim(flds_scalar_name))
       call fld_list_add(fldsToIce_num, fldsToIce, 'So_dhdx'       )
       call fld_list_add(fldsToIce_num, fldsToIce, 'So_dhdy'       )
       call fld_list_add(fldsToIce_num, fldsToIce, 'So_t'          )
       call fld_list_add(fldsToIce_num, fldsToIce, 'So_s'          )
       call fld_list_add(fldsToIce_num, fldsToIce, 'So_u'          )
       call fld_list_add(fldsToIce_num, fldsToIce, 'So_v'          )
       call fld_list_add(fldsToIce_num, fldsToIce, 'Fioo_q'        )
       call fld_list_add(fldsToIce_num, fldsToIce, 'Sa_z'          )
       call fld_list_add(fldsToIce_num, fldsToIce, 'Sa_u'          )
       call fld_list_add(fldsToIce_num, fldsToIce, 'Sa_v'          )
       call fld_list_add(fldsToIce_num, fldsToIce, 'Sa_ptem'       )
       call fld_list_add(fldsToIce_num, fldsToIce, 'Sa_shum'       )
       call fld_list_add(fldsToIce_num, fldsToIce, 'Sa_dens'       )
       call fld_list_add(fldsToIce_num, fldsToIce, 'Sa_tbot'       )
       call fld_list_add(fldsToIce_num, fldsToIce, 'Faxa_swvdr'    )
       call fld_list_add(fldsToIce_num, fldsToIce, 'Faxa_swndr'    )
       call fld_list_add(fldsToIce_num, fldsToIce, 'Faxa_swvdf'    )
       call fld_list_add(fldsToIce_num, fldsToIce, 'Faxa_swndf'    )
       call fld_list_add(fldsToIce_num, fldsToIce, 'Faxa_lwdn'     )
       call fld_list_add(fldsToIce_num, fldsToIce, 'Faxa_rain'     )
       call fld_list_add(fldsToIce_num, fldsToIce, 'Faxa_snow'     )
       call fld_list_add(fldsToIce_num, fldsToIce, 'Faxa_bcph'  , ungridded_lbound=1, ungridded_ubound=3)
       call fld_list_add(fldsToIce_num, fldsToIce, 'Faxa_ocph'  , ungridded_lbound=1, ungridded_ubound=3)
       call fld_list_add(fldsToIce_num, fldsToIce, 'Faxa_dstwet', ungridded_lbound=1, ungridded_ubound=4)
       call fld_list_add(fldsToIce_num, fldsToIce, 'Faxa_dstdry', ungridded_lbound=1, ungridded_ubound=4)

       do n = 1,fldsFrIce_num
          if(mastertask) write(logunit,*)'Advertising From Xice ',trim(fldsFrIce(n)%stdname)
          call NUOPC_Advertise(exportState, standardName=fldsFrIce(n)%stdname, &
               TransferOfferGeomObject='will provide', rc=rc)
          if (chkerr(rc,__LINE__,u_FILE_u)) return
       enddo

       do n = 1,fldsToIce_num
          if(mastertask) write(logunit,*)'Advertising To Xice ',trim(fldsToIce(n)%stdname)
          call NUOPC_Advertise(importState, standardName=fldsToIce(n)%stdname, &
               TransferOfferGeomObject='will provide', rc=rc)
          if (chkerr(rc,__LINE__,u_FILE_u)) return
       end do
    end if


    if (dbug > 5) call ESMF_LogWrite(subname//' done', ESMF_LOGMSG_INFO, rc=rc)

    !----------------------------------------------------------------------------
    ! Reset shr logging to original values
    !----------------------------------------------------------------------------

    call shr_file_setLogUnit (shrlogunit)

  end subroutine InitializeAdvertise

  !===============================================================================

  subroutine InitializeRealize(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    ! local variables
    character(ESMF_MAXSTR) :: convCIM, purpComp
    type(ESMF_Mesh)        :: Emesh
    integer                :: shrlogunit                ! original log unit
    integer                :: n
    character(len=*),parameter :: subname=trim(modName)//':(InitializeRealize) '
    !-------------------------------------------------------------------------------

    rc = ESMF_SUCCESS
    if (dbug > 5) call ESMF_LogWrite(subname//' called', ESMF_LOGMSG_INFO, rc=rc)

    !----------------------------------------------------------------------------
    ! Reset shr logging to my log file
    !----------------------------------------------------------------------------

    call shr_file_getLogUnit (shrlogunit)
    call shr_file_setLogUnit (logUnit)

    !--------------------------------
    ! generate the mesh
    !--------------------------------

    call dead_meshinit(gcomp, nxg, nyg, gindex, lon, lat, Emesh, rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    !--------------------------------
    ! realize the actively coupled fields, now that a mesh is established
    ! NUOPC_Realize "realizes" a previously advertised field in the importState and exportState
    ! by replacing the advertised fields with the newly created fields of the same name.
    !--------------------------------

    call fld_list_realize( &
         state=ExportState, &
         fldlist=fldsFrIce, &
         numflds=fldsFrIce_num, &
         flds_scalar_name=flds_scalar_name, &
         flds_scalar_num=flds_scalar_num, &
         tag=subname//':diceExport',&
         mesh=Emesh, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    call fld_list_realize( &
         state=importState, &
         fldList=fldsToIce, &
         numflds=fldsToIce_num, &
         flds_scalar_name=flds_scalar_name, &
         flds_scalar_num=flds_scalar_num, &
         tag=subname//':diceImport',&
         mesh=Emesh, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    !--------------------------------
    ! Pack export state
    !--------------------------------

    call state_setexport(exportState, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    call shr_nuopc_methods_State_SetScalar(dble(nxg),flds_scalar_index_nx, exportState, &
         flds_scalar_name, flds_scalar_num, rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    call shr_nuopc_methods_State_SetScalar(dble(nyg),flds_scalar_index_ny, exportState, &
         flds_scalar_name, flds_scalar_num, rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    !--------------------------------
    ! diagnostics
    !--------------------------------

    if (dbug > 1) then
       call shr_nuopc_methods_State_diagnose(exportState,subname//':ES',rc=rc)
       if (chkerr(rc,__LINE__,u_FILE_u)) return
    endif

#ifdef USE_ESMF_METADATA
    convCIM  = "CIM"
    purpComp = "Model Component Simulation Description"
    call ESMF_AttributeAdd(comp,  convention=convCIM, purpose=purpComp, rc=rc)
    call ESMF_AttributeSet(comp, "ShortName", "XICE", convention=convCIM, purpose=purpComp, rc=rc)
    call ESMF_AttributeSet(comp, "LongName", "Sea Ice Dead Model", convention=convCIM, purpose=purpComp, rc=rc)
    call ESMF_AttributeSet(comp, "Description", &
         "The dead models stand in as test model for active components." // &
         "Coupling data is artificially generated ", convention=convCIM, purpose=purpComp, rc=rc)
    call ESMF_AttributeSet(comp, "ReleaseDate", "2017", convention=convCIM, purpose=purpComp, rc=rc)
    call ESMF_AttributeSet(comp, "ModelType", "Sea Ice", convention=convCIM, purpose=purpComp, rc=rc)
#endif

    call shr_file_setLogUnit (shrlogunit)

    if (dbug > 5) call ESMF_LogWrite(subname//' done', ESMF_LOGMSG_INFO, rc=rc)

  end subroutine InitializeRealize

  !===============================================================================

  subroutine ModelAdvance(gcomp, rc)

    use shr_nuopc_utils_mod, only : shr_nuopc_memcheck, shr_nuopc_log_clock_advance

    ! input/output variables
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    ! local variables
    type(ESMF_Clock)  :: clock
    type(ESMF_State)  :: exportState
    integer           :: shrlogunit     ! original log unit
    character(len=*),parameter  :: subname=trim(modName)//':(ModelAdvance) '
    !-------------------------------------------------------------------------------

    rc = ESMF_SUCCESS
    call ESMF_LogWrite(subname//' called', ESMF_LOGMSG_INFO, rc=rc)
    call shr_nuopc_memcheck(subname, 3, mastertask)

    call shr_file_getLogUnit (shrlogunit)
    call shr_file_setLogUnit (logunit)

    !--------------------------------
    ! Pack export state
    !--------------------------------

    call NUOPC_ModelGet(gcomp, modelClock=clock, exportState=exportState, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    call state_setexport(exportState,  rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    !--------------------------------
    ! diagnostics
    !--------------------------------

    if (dbug > 1) then
       call shr_nuopc_methods_State_diagnose(exportState,subname//':ES',rc=rc)
       if (chkerr(rc,__LINE__,u_FILE_u)) return
       if (my_task == master_task) then
          call shr_nuopc_log_clock_advance(clock, 'ICE', logunit)
       endif
    endif

    call shr_file_setLogUnit (shrlogunit)

    call ESMF_LogWrite(subname//' done', ESMF_LOGMSG_INFO, rc=rc)

  end subroutine ModelAdvance

  !===============================================================================

  subroutine state_setexport(exportState, rc)

    ! input/output variables
    type(ESMF_State)  , intent(inout) :: exportState
    integer, intent(out) :: rc

    ! local variables
    integer :: nf, nind
    !--------------------------------------------------

    rc = ESMF_SUCCESS

    ! Start from index 2 in order to skip the scalar field 
    do nf = 2,fldsFrIce_num
       if (fldsFrIce(nf)%ungridded_ubound == 0) then
          call field_setexport(exportState, trim(fldsFrIce(nf)%stdname), lon, lat, nf=nf, rc=rc)
          if (chkerr(rc,__LINE__,u_FILE_u)) return
       else
          do nind = 1,fldsFrIce(nf)%ungridded_ubound
             call field_setexport(exportState, trim(fldsFrIce(nf)%stdname), lon, lat, nf=nf+nind-1, &
                  ungridded_index=nind, rc=rc)
             if (chkerr(rc,__LINE__,u_FILE_u)) return
          end do
       end if
    end do

  end subroutine state_setexport

  !===============================================================================

  subroutine field_setexport(exportState, fldname, lon, lat, nf, ungridded_index, rc)

    use shr_const_mod , only : pi=>shr_const_pi

    ! intput/otuput variables
    type(ESMF_State)  , intent(inout) :: exportState
    character(len=*)  , intent(in)    :: fldname
    real(r8)          , intent(in)    :: lon(:)
    real(r8)          , intent(in)    :: lat(:)
    integer           , intent(in)    :: nf
    integer, optional , intent(in)    :: ungridded_index
    integer           , intent(out)   :: rc

    ! local variables
    integer           :: i, ncomp
    type(ESMF_Field)  :: lfield
    real(r8), pointer :: data1d(:)
    real(r8), pointer :: data2d(:,:)
    !--------------------------------------------------

    rc = ESMF_SUCCESS

    call ESMF_StateGet(exportState, itemName=trim(fldname), field=lfield, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    ncomp = 3
    if (present(ungridded_index)) then
       call ESMF_FieldGet(lfield, farrayPtr=data2d, rc=rc)
       if (chkerr(rc,__LINE__,u_FILE_u)) return
       if (gridToFieldMap == 1) then
          do i = 1,size(data2d, dim=1)
             data2d(i,ungridded_index) = (nf*100) * cos(pi*lat(i)/180.0_R8) * &
                  sin((pi*lon(i)/180.0_R8) - (ncomp-1)*(pi/3.0_R8) ) + (ncomp*10.0_R8)
          end do
       else if (gridToFieldMap == 2) then
          do i = 1,size(data2d, dim=2)
             data2d(ungridded_index,i) = (nf*100) * cos(pi*lat(i)/180.0_R8) * &
                  sin((pi*lon(i)/180.0_R8) - (ncomp-1)*(pi/3.0_R8) ) + (ncomp*10.0_R8)
          end do
       end if
    else
       call ESMF_FieldGet(lfield, farrayPtr=data1d, rc=rc)
       if (chkerr(rc,__LINE__,u_FILE_u)) return
       do i = 1,size(data1d)
          data1d(i) = (nf*100) * cos(pi*lat(i)/180.0_R8) * &
               sin((pi*lon(i)/180.0_R8) - (ncomp-1)*(pi/3.0_R8) ) + (ncomp*10.0_R8)
       end do
       ! Reset some fields
       if (fldname == 'Si_ifrac') then
          do i = 1,size(data1d)
             data1d(i) =  min(1.0_R8,max(0.0_R8,data1d(i)))
          end do
       else if (fldname == 'Si_imask') then
          do i = 1,size(data1d)
             data1d(i) = float(nint(min(1.0_R8,max(0.0_R8,data1d(i)))))
          end do
       end if
    end if

  end subroutine field_setexport

  !===============================================================================

  subroutine ModelFinalize(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    ! local variables
    character(len=*),parameter  :: subname=trim(modName)//':(ModelFinalize) '
    !-------------------------------------------------------------------------------

    !--------------------------------
    ! Finalize routine
    !--------------------------------

    rc = ESMF_SUCCESS
    if (dbug > 5) call ESMF_LogWrite(subname//' called', ESMF_LOGMSG_INFO, rc=rc)

    call dead_final_nuopc('ice', logunit)

    if (dbug > 5) call ESMF_LogWrite(subname//' done', ESMF_LOGMSG_INFO, rc=rc)

  end subroutine ModelFinalize

end module ice_comp_nuopc
