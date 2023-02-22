! Copyright 2020 elphbolt contributors.
! This file is part of elphbolt <https://github.com/nakib/elphbolt>.
!
! elphbolt is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! elphbolt is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with elphbolt. If not, see <http://www.gnu.org/licenses/>.

module wannier_module
  !! Module containing type and procedures related to Wannierization.

  use params, only: r64, i64, Ryd2eV, Ryd2radTHz, oneI, pi, twopi, twopiI, &
       Ryd2amu, bohr2nm
  use misc, only: exit_with_message, print_message, expi, twonorm, &
       distribute_points, demux_state, mux_vector, subtitle, cross_product
  use numerics_module, only: numerics
  use crystal_module, only: crystal
  
  implicit none

  private
  public epw_wannier

  !external chdir
  
  type epw_wannier
     !! Data and procedures related to Wannierization.

     integer(i64) :: numwannbands
     !! Number of Wannier bands.
     integer(i64) :: numbranches
     !! Number of phonon branches.
     integer(i64) :: nwsk
     !! Number of real space cells for electrons.
     integer(i64) :: coarse_qmesh(3)
     !! Coarse phonon wave vector mesh in Wannier calculation.
     integer(i64) :: nwsq
     !! Number of real space cells for phonons.
     integer(i64) :: nwsg
     !! Number of real space cells for electron-phonon vertex.
     integer(i64), allocatable :: rcells_k(:, :)
     !! Real space cell locations for electrons.
     integer(i64), allocatable :: rcells_q(:, :)
     !! Real space cell locations for phonons.
     integer(i64), allocatable :: rcells_g(:, :)
     !! Real space cell locations for electron-phonon vertex.     
     integer(i64), allocatable :: elwsdeg(:)
     !! Real space cell multiplicity for electrons.
     integer(i64), allocatable :: phwsdeg(:)
     !! Real space cell multiplicity for phonons.
     integer(i64), allocatable :: gwsdeg(:)
     !! Real space cell multiplicity for electron-phonon vertex.
     complex(r64), allocatable :: Hwann(:, :, :)
     !! Hamiltonian in Wannier representation.
     complex(r64), allocatable :: Dphwann(:, :, :)
     !! Dynamical matrix in Wannier representation.
     complex(r64), allocatable :: gwann(:, :, :, :, :)
     !! e-ph vertex in Wannier representation.

   contains

     procedure :: read=>read_EPW_Wannier, el_wann_epw, ph_wann_epw, &
          gkRp_epw, gReq_epw, g2_epw, deallocate_wannier, plot_along_path

  end type epw_wannier

contains

  subroutine read_EPW_Wannier(self, num)
    !! Read Wannier representation of the hamiltonian, dynamical matrix, and the
    !! e-ph matrix elements from file epwdata.fmt.

    class(epw_wannier), intent(out) :: self
    type(numerics), intent(in) :: num
    
    !Local variables
    integer(i64) :: iuc, ib, jb
    integer(i64) :: coarse_qmesh(3)
    real(r64) :: ef
    real(r64), allocatable :: dummy(:)
    ! EPW File names:
    character(len=*), parameter :: filename_epwdata = "epwdata.fmt"
    character(len=*), parameter :: filename_epwgwann = "epmatwp1"
    character(len=*), parameter :: filename_elwscells = "rcells_k"
    character(len=*), parameter :: filename_phwscells = "rcells_q"
    character(len=*), parameter :: filename_gwscells = "rcells_g"
    character(len=*), parameter :: filename_elwsdeg = "wsdeg_k"
    character(len=*), parameter :: filename_phwsdeg = "wsdeg_q"
    character(len=*), parameter :: filename_gwsdeg = "wsdeg_g"

    namelist /wannier/ coarse_qmesh

    call subtitle("Reading EPW Wannier information...")

    !Open input file
    open(1, file = 'input.nml', status = 'old')

    coarse_qmesh = (/0, 0, 0/)
    read(1, nml = wannier)
    if(any(coarse_qmesh <= 0)) then
       call exit_with_message('Bad input(s) in wannier.')
    end if
    self%coarse_qmesh = coarse_qmesh
    
    !Close input file
    close(1)
    
    open(1,file=filename_epwdata,status='old')
    read(1,*) ef !Fermi energy. Read but ignored here.
    read(1,*) self%numwannbands, self%nwsk, self%numbranches, self%nwsq, self%nwsg
    allocate(dummy((self%numbranches/3 + 1)*9)) !numatoms*9 Born, 9 epsilon elements.
    read(1,*) dummy !Born, epsilon. Read but ignored here.

    !Read real space hamiltonian
    call print_message("Reading Wannier rep. Hamiltonian...")
    allocate(self%Hwann(self%nwsk,self%numwannbands,self%numwannbands))
    do ib = 1,self%numwannbands
       do jb = 1,self%numwannbands
          do iuc = 1,self%nwsk !Number of real space electron cells
             read (1, *) self%Hwann(iuc,ib,jb)
          end do
       end do
    end do

    !Read real space dynamical matrix
    call print_message("Reading Wannier rep. dynamical matrix...")
    allocate(self%Dphwann(self%nwsq,self%numbranches,self%numbranches))
    do ib = 1,self%numbranches
       do jb = 1,self%numbranches
          do iuc = 1,self%nwsq !Number of real space phonon cells
             read (1, *) self%Dphwann(iuc,ib,jb)
          end do
       end do
    end do
    close(1)

    if(.not. num%read_gk2 .or. .not. num%read_gq2 .or. &
         num%plot_along_path) then
       !Read real space matrix elements
       call print_message("Reading Wannier rep. e-ph vertex...")
       open(1, file = filename_epwgwann, status = 'old', access = 'stream')
       allocate(self%gwann(self%numwannbands,self%numwannbands,self%nwsk,&
            self%numbranches,self%nwsg))
       self%gwann = 0.0_r64
       read(1) self%gwann
    end if
    close(1)

    !Read cell maps of q, k, g meshes.
    call print_message("Reading Wannier cells and multiplicities...")
    allocate(self%rcells_k(self%nwsk,3))
    allocate(self%elwsdeg(self%nwsk))
    open(1, file = filename_elwscells, status = "old")
    open(2, file = filename_elwsdeg, status = "old")
    do iuc = 1,self%nwsk
       read(1, *) self%rcells_k(iuc, :)
       read(2, *) self%elwsdeg(iuc)
    end do
    close(1)
    close(2)

    allocate(self%rcells_q(self%nwsq, 3))
    allocate(self%phwsdeg(self%nwsq))
    open(1, file = filename_phwscells, status = "old")
    open(2, file = filename_phwsdeg, status = "old")
    do iuc = 1,self%nwsq
       read(1, *) self%rcells_q(iuc, :)
       read(2, *) self%phwsdeg(iuc)
    end do
    close(1)
    close(2)

    allocate(self%rcells_g(self%nwsg, 3))
    allocate(self%gwsdeg(self%nwsg))
    open(1, file = filename_gwscells, status = "old")
    open(2, file = filename_gwsdeg, status = "old")
    do iuc = 1,self%nwsg
       read(1, *) self%rcells_g(iuc, :)
       read(2, *) self%gwsdeg(iuc)
    end do
    close(1)
    close(2)
  end subroutine read_EPW_Wannier

  subroutine el_wann_epw(self, crys, nk, kvecs, energies, velocities, evecs, scissor)
    !! Wannier interpolate electrons on list of arb. k-vecs

    class(epw_wannier), intent(in) :: self
    type(crystal), intent(in) :: crys
    integer(i64), intent(in) :: nk
    real(r64), intent(in) :: kvecs(nk,3) !Crystal coordinates
    real(r64), intent(out) :: energies(nk,self%numwannbands)
    real(r64), optional, intent(out) :: velocities(nk,self%numwannbands,3)
    complex(r64), optional, intent(out) :: evecs(nk,self%numwannbands,self%numwannbands)
    real(r64), optional, intent(in) :: scissor(self%numwannbands)

    !Local variables
    integer(i64) :: iuc, ib, jb, ipol, ik, nwork, tmp
    real(r64) :: rcart(3)
    real(r64),  allocatable :: rwork(:)
    complex(r64), allocatable :: work(:)
    complex(r64) :: caux, H(self%numwannbands,self%numwannbands), &
         dH(3,self%numwannbands,self%numwannbands)

    !External procedures
    external :: zheev
    
    !Catch error for optional velocity calculation
    if(present(velocities) .and. .not. present(evecs)) &
         call exit_with_message("In Wannier, velocity is present but not eigenvecs.")

    nwork = 1
    allocate(work(nwork))
    allocate(rwork(max(1,7*self%numwannbands)))
    
    do ik = 1,nk
       !Form Hamiltonian (H) and k-derivative of H (dH) 
       !from Hwann, rcells_k, and elwsdeg
       H = 0
       dH = 0
       do iuc = 1,self%nwsk
          caux = expi(twopi*dot_product(kvecs(ik,:),self%rcells_k(iuc,:)))&
               /self%elwsdeg(iuc)
          H = H + caux*self%Hwann(iuc,:,:)

          if(present(velocities)) then
             rcart = matmul(crys%lattvecs,self%rcells_k(iuc,:))
             do ipol = 1,3
                dH(ipol,:,:) = dH(ipol,:,:) + &
                     oneI*rcart(ipol)*caux*self%Hwann(iuc,:,:)
             end do
          end if
       end do

       !Force Hermiticity
       do ib = 1, self%numwannbands
          do jb = ib + 1, self%numwannbands
             H(ib,jb) = (H(ib,jb) + conjg(H(jb,ib)))*0.5_r64
             H(jb,ib) = H(ib,jb)
          end do
       end do

       !Diagonalize H
       call zheev("V", "U", self%numwannbands, H(:,:), self%numwannbands, energies(ik,:), &
            work, -1_i64, rwork, tmp)
       if(real(work(1)) > nwork) then
          nwork = nint(2*real(work(1)))
          deallocate(work)
          allocate(work(nwork))
       end if
       call zheev("V", "U", self%numwannbands, H(:,:), self%numwannbands, energies(ik,:), &
            work, nwork, rwork, tmp)

       !These quantities are U^dagger. See Eq. 31 or prb 76, 165108.
       if(present(evecs)) then
          evecs(ik,:,:)=transpose(H(:,:))
       end if

       if(present(velocities)) then
          !Calculate velocities using Feynman-Hellmann thm
          do ib = 1,self%numwannbands
             do ipol = 1,3
                velocities(ik,ib,ipol)=real(dot_product(evecs(ik,ib,:), &
                     matmul(dH(ipol,:,:), evecs(ik,ib,:))))
             end do
          end do
       end if

       !energies(ik,:) = energies(ik,:)*Rydberg2radTHz !2piTHz
       energies(ik,:) = energies(ik,:)*Ryd2eV !eV
       !If present, apply the scissor operator to conduction bands
       if (present(scissor)) then
          energies(ik,:) = energies(ik,:) + scissor(:)
       end if
       if(present(velocities)) then
          velocities(ik,:,:) = velocities(ik,:,:)*Ryd2radTHz !nmTHz = Km/s
       end if
    end do !ik
  end subroutine el_wann_epw

  subroutine ph_wann_epw(self, crys, nq, qvecs, energies, evecs)  
    !! Wannier interpolate phonons on list of arb. q-vec

    class(epw_wannier), intent(in) :: self
    type(crystal), intent(in) :: crys

    !Local variables
    integer(i64), intent(in) :: nq
    real(r64), intent(in) :: qvecs(nq, 3) !Crystal coordinates
    real(r64), intent(out) :: energies(nq, self%numbranches)
    complex(r64), intent(out), optional :: evecs(nq, self%numbranches, self%numbranches)
    
    integer(i64) :: iuc, ib, jb, iq, na, nb, nwork, aux
    complex(r64) :: caux
    real(r64), allocatable :: rwork(:)
    complex(r64), allocatable :: work(:)
    real(r64) :: omega2(self%numbranches), massnorm
    complex(r64) :: dynmat(self%numbranches, self%numbranches)

    !External procedures
    external :: zheev
    
    nwork = 1
    allocate(work(nwork))
    allocate(rwork(max(1, 9*crys%numatoms-2)))
    
    do iq = 1, nq
       !Form dynamical matrix
       dynmat = (0.0_r64, 0.0_r64)
       do iuc = 1, self%nwsq
          caux = expi(twopi*dot_product(qvecs(iq, :), self%rcells_q(iuc, :)))&
               /self%phwsdeg(iuc)
          
          dynmat = dynmat + caux*self%Dphwann(iuc, :, :)
       end do
       
       !Non-analytic correction
       if(crys%polar) then
          call dyn_nonanalytic(self, crys, matmul(crys%reclattvecs,qvecs(iq,:))*bohr2nm, dynmat)
       end if

       !Force Hermiticity
       do ib = 1, self%numbranches
          do jb = ib + 1, self%numbranches
             dynmat(ib, jb) = (dynmat(ib, jb) + conjg(dynmat(jb, ib)))*0.5_r64
             dynmat(jb, ib) = dynmat(ib, jb)
          end do
       end do
       
       !Mass normalize
       do na = 1, crys%numatoms
          do nb = 1, crys%numatoms
             massnorm = 1.d0/sqrt(crys%masses(crys%atomtypes(na))*&
                  crys%masses(crys%atomtypes(nb)))*Ryd2amu
             dynmat(3*(na-1)+1:3*na, 3*(nb-1)+1:3*nb) = &
                  dynmat(3*(na-1)+1:3*na, 3*(nb-1)+1:3*nb)*massnorm
          end do
       end do
       
       !Diagonalize dynmat
       call zheev("V", "U", self%numbranches, dynmat(:, :), self%numbranches, omega2, work, -1_i64, rwork, aux)
       if(real(work(1)) > nwork) then
          nwork = nint(2*real(work(1)))
          deallocate(work)
          allocate(work(nwork))
       end if
       call zheev("V", "U", self%numbranches, dynmat(:, :), self%numbranches, omega2, work, nwork, rwork, aux)

       energies(iq, :) = sign(sqrt(abs(omega2)), omega2)

       !These quantities are u. See Eq. 32 or prb 76, 165108.
       if(present(evecs)) then
          evecs(iq, :, :) = transpose(dynmat(:, :))
       end if

       !energies(iq, :) = energies(iq, :)*Rydberg2radTHz !2piTHz
       !energies(iq, :) = energies(iq, :)*Rydberg2eV*1.0e3_r64 !meV
       energies(iq, :) = energies(iq, :)*Ryd2eV !eV
       
       !Take care of gamma point.
       if(all(qvecs(iq,:) == 0)) then
          energies(iq, 1:3) = 0
       end if
       
       !Handle negative energy phonons
       do ib = 1, self%numbranches
          if(energies(iq,ib) < -0.005_r64) then
             call exit_with_message('Large negative phonon energy found! Stopping!')             
          else if(energies(iq,ib) < 0 .and. energies(iq,ib) > -0.005_r64) then
             energies(iq,ib) = 0
          end if
       end do
    end do !iq
  end subroutine ph_wann_epw

  subroutine dyn_nonanalytic(self, crys, q, dyn)
    !! Calculate the long-range correction to the
    !! dynamical matrix and its derivative for a given phonon mode.
    !!
    !! q: the phonon wave vector in Cartesian coords., Bohr^-1
    !! dyn: the dynamical matrix
    !
    ! This is adapted from ShengBTE's subroutine phonon_espresso.
    ! The 2D vesion is taken from rigid_epw.f90 of EPW
    ! ShengBTE is distributed under GPL v3 or later.

    class(epw_wannier), intent(in) :: self
    type(crystal), intent(in) :: crys
    
    !Local variables
    real(r64), intent(in) :: q(3) !Cartesian
    complex(r64), intent(inout) :: dyn(self%numbranches,self%numbranches)

    complex(r64) :: dyn_l(self%numbranches,self%numbranches), fnat(3)
    real(r64) :: qeq, arg, zig(3), zjg(3), g(3), gmax, alph, &
         tpiba, rr(crys%numatoms,crys%numatoms,3), &
         qrq, c, area, reff(2,2)
    integer(i64) :: iat,jat,idim,jdim,ipol,jpol,m1,m2,m3,nq1,nq2,nq3
    complex(r64) :: fac, facqd, facq
    
    tpiba = twopi/twonorm(crys%lattvecs(:,1))*bohr2nm

    !Recall that the phonon supercell in elphbolt is the
    !same as the EPW coarse phonon mesh.
    nq1 = self%coarse_qmesh(1)
    nq2 = self%coarse_qmesh(2)
    if (crys%twod) then
      nq3 = 0
    else
      nq3 = self%coarse_qmesh(3)
    end if

    gmax= 14.0_r64 !dimensionless
    alph= tpiba**2 !bohr^-2


    !Compute
    if (crys%twod) then
      ! Vacuum size in Bohr unit
      c = twopi/(crys%reclattvecs(3,3)*bohr2nm)
      ! Area in nm**2
      area = twonorm(cross_product( crys%lattvecs(:,1),&
         crys%lattvecs(:,2)))
      !In Ry units, qe = sqrt(2.0)
      fac =  4.0_r64*pi/(area/bohr2nm**2)
      ! Effective screening length
      ! reff = (epsilon - 1) * c/2
      reff(:, :) = 0.0_r64
      reff(:, :) = crys%epsilon(1:2, 1:2) * 0.5_r64 * c ! eps * c/2
      reff(1, 1) = reff(1, 1) - 0.5_r64 * c ! (-1) * c/2
      reff(2, 2) = reff(2, 2) - 0.5_r64 * c ! (-1) * c/2
    else
      !In Ry units, qe = sqrt(2.0)
      fac = 8.0_r64*pi/(crys%volume/bohr2nm**3)
    end if

    dyn_l = (0.0_r64, 0.0_r64)
    do m1 = -nq1,nq1
       do m2 = -nq2,nq2
          do m3 = -nq3,nq3
             g(:) = (m1*crys%reclattvecs(:,1)+m2*crys%reclattvecs(:,2)+m3*crys%reclattvecs(:,3))*bohr2nm

             if(crys%twod) then
               qeq = g(1)**2 + g(2)**2 + g(3)**2
               qrq = 0.0_r64
               if (g(1)**2 + g(2)**2 > 1.0e-8_r64) then
                  qrq = g(1) * reff(1, 1) * g(1) + g(1) * reff(1, 2) * g(2) + g(2) * reff(2, 1) * g(1) + g(2) * reff(2, 2) * g(2)
                  qrq = qrq / (g(1)**2 + g(2)**2)
               end if
             else
               qeq = dot_product(g,matmul(crys%epsilon,g))
             end if

             if (qeq > 0.0_r64 .and. qeq/alph/4.0_r64 < gmax ) then
                if(crys%twod) then
                  facqd = exp(-qeq/alph/4.0_r64)/sqrt(qeq)/(1.0_r64 + qrq * sqrt(qeq))
                else
                  facqd = exp(-qeq/alph/4.0_r64)/qeq
                end if
                do iat = 1,crys%numatoms
                   zig(:)=matmul(g,crys%born(:,:,iat))
                   fnat(:)= (0.0_r64,0.0_r64)
                   do jat = 1,crys%numatoms
                      rr(iat,jat,:) = (crys%basis_cart(:,iat)-crys%basis_cart(:,jat))/bohr2nm
                      arg = dot_product(g,rr(iat,jat,:))
                      zjg(:) = matmul(g,crys%born(:,:,jat))
                      fnat(:) = fnat(:) + zjg(:)*expi(arg)
                   end do
                   do ipol=1,3
                      idim=(iat-1)*3+ipol
                      do jpol=1,3
                         jdim=(iat-1)*3+jpol
                         dyn_l(idim,jdim) = dyn_l(idim,jdim) - &
                              facqd*zig(ipol)*fnat(jpol)
                      end do
                   end do
                end do
             end if

             !Shifted sum
             g = g + q

             if(crys%twod) then
               qeq = g(1)**2 + g(2)**2 + g(3)**2
               qrq = 0.0_r64
               if (g(1)**2 + g(2)**2 > 1.0e-8_r64) then
                  qrq = g(1) * reff(1, 1) * g(1) + g(1) * reff(1, 2) * g(2) + g(2) * reff(2, 1) * g(1) + g(2) * reff(2, 2) * g(2)
                  qrq = qrq / (g(1)**2 + g(2)**2)
               end if
             else
               qeq = dot_product(g,matmul(crys%epsilon,g))
             end if

             if (qeq > 0.0_r64 .and. qeq/alph/4.0_r64 < gmax ) then
                if(crys%twod) then
                  facqd = exp(-qeq/alph/4.0_r64)/sqrt(qeq)/(1.0_r64 + qrq * sqrt(qeq))
                else
                  facqd = exp(-qeq/alph/4.0_r64)/qeq
                end if
                do iat = 1,crys%numatoms
                   zig(:)=matmul(g,crys%born(:,:,iat))                   
                   do jat = 1,crys%numatoms
                      rr(iat,jat,:) = (crys%basis_cart(:,iat)-crys%basis_cart(:,jat))/bohr2nm
                      zjg(:)=matmul(g,crys%born(:,:,jat))
                      arg = dot_product(g,rr(iat,jat,:))
                      facq = facqd*expi(arg)
                      do ipol=1,3
                         idim=(iat-1)*3+ipol
                         do jpol=1,3
                            jdim=(jat-1)*3+jpol
                            dyn_l(idim,jdim) = dyn_l(idim,jdim) + facq * &
                                 zig(ipol)*zjg(jpol)
                         end do
                      end do
                   end do
                end do
             end if
          end do
       end do
    end do
    dyn = dyn + dyn_l*fac
  end subroutine dyn_nonanalytic

  function g2_epw(self, crys, kvec, qvec, el_evec_k, el_evec_kp, ph_evec_q, ph_en, &
       gmixed, wannspace)
    !! Function to calculate |g|^2.
    !! This works with EPW real space data
    !! kvec: electron wave vector in crystal coords
    !! qvec: phonon wave vector in crystal coords
    !! el_evec_k(kp): initial(final) electron eigenvector in bands m(n) 
    !! ph_evec_q: phonon eigenvector branchs 
    !! ph_en: phonon energy in mode (s,qvec)
    !! gmixed: e-ph matrix element in mixed Wannier-Bloch representation
    !! wannspace: the species that is in Wannier representation

    class(epw_wannier), intent(in) :: self
    type(crystal), intent(in) :: crys
    
    real(r64),intent(in) :: kvec(3), qvec(3), ph_en
    complex(r64),intent(in) :: el_evec_k(self%numwannbands),&
         el_evec_kp(self%numwannbands), ph_evec_q(self%numbranches), &
         gmixed(:,:,:,:)
    character(len = 2) :: wannspace
    real(r64), parameter :: g2unitfactor = Ryd2eV**3*Ryd2amu
    
    !Local variables
    integer(i64) :: ip, iws, nws, np, mp, sp, mtype
    complex(r64) :: caux, u(self%numbranches), gbloch, unm, &
         overlap(self%numwannbands,self%numwannbands), glprefac
    complex(r64), allocatable :: UkpgUkdag(:, :), UkpgUkdaguq(:)
    real(r64) :: g2_epw

    if(wannspace /= 'el' .and. wannspace /= 'ph') then
       call exit_with_message(&
            "Invalid value of wannspace in call to g2_epw. Exiting.")
    end if
    
    !Mass normalize the phonon matrix
    do ip = 1, self%numbranches ! d.o.f of basis atoms
       !demux atom type from d.o.f
       mtype = (ip - 1)/3 + 1 
       !normalize
       u(ip) = ph_evec_q(ip)/sqrt(crys%masses(crys%atomtypes(mtype)))
    end do

    if(ph_en == 0) then !zero out matrix elements for zero energy phonons
       g2_epw = 0
    else
       if(wannspace == 'ph') then
          nws = self%nwsg
       else
          nws = self%nwsk
       end if
       
       allocate(UkpgUkdag(self%numbranches, nws), UkpgUkdaguq(nws))
       !See Eq. 22 of prb 76, 165108.
       UkpgUkdag = 0 !g(k,Rp) or g(Re,q) (un)rotated by the electron U^\dagger(k) and U(k') matrices
       UkpgUkdaguq = 0 !above quantity (un)rotated by the phonon u(q) matrix
       gbloch = 0

       !Create the matrix U_nn'(k')U_m'm^\dagger(k)
       do np = 1, self%numwannbands !over final electron band
          do mp = 1, self%numwannbands !over initial electron band
             !(Recall that the electron eigenvectors came out daggered from el_wann_epw.)
             overlap(mp,np) = conjg(el_evec_kp(np))*el_evec_k(mp)
          end do
       end do
       
       do iws = 1, nws !over matrix elements WS cell
          !Apply electron rotations
          do sp = 1, self%numbranches
             caux = 0
             do np = 1, self%numwannbands !over final electron band
                do mp = 1, self%numwannbands !over initial electron band
                   caux = caux + overlap(mp,np)*gmixed(np, mp, sp, iws)
                end do
             end do
             UkpgUkdag(sp, iws) = UkpgUkdag(sp, iws) + caux
          end do
       end do

       do iws = 1, nws !over matrix elements WS cell
          !Apply phonon rotation
          !(Recall that the phonon eigenvector *did not* come out pre-daggered from ph_wann_epw.)
          UkpgUkdaguq(iws) = UkpgUkdaguq(iws) + dot_product(conjg(u),UkpgUkdag(:, iws))
       end do

       do iws = 1, nws !over matrix elements WS cell
          !Fourier transform to reciprocal-space
          if(wannspace == 'ph') then
             caux = expi(twopi*dot_product(qvec, self%rcells_g(iws, :)))&
                  /self%gwsdeg(iws)
          else
             caux = expi(twopi*dot_product(kvec, self%rcells_k(iws,:)))&
                  /self%elwsdeg(iws)
          end if
          gbloch = gbloch + caux*UkpgUkdaguq(iws)
       end do

       if(crys%polar) then !Long-range correction
          !This is [U(k')U^\dagger(k)]_nm, the overlap factor in the dipole correction.
          !(Recall that the electron eigenvectors came out daggered from el_wann_epw.)
          unm = dot_product(el_evec_kp,el_evec_k)
          call long_range_prefac(self, crys, &
               matmul(crys%reclattvecs,qvec)*bohr2nm,u,glprefac)
          gbloch = gbloch + glprefac*unm
       end if

       g2_epw = 0.5_r64*real(gbloch*conjg(gbloch))/ &
            ph_en*g2unitfactor !eV^2
    end if
  end function g2_epw
  
  subroutine long_range_prefac(self, crys, q, uqs, glprefac)
    !! Calculate the long-range correction prefactor of
    !! the e-ph matrix element for a given phonon mode.
    !! q: phonon wvec in Cartesian coords., Bohr^-1
    !! uqs: phonon eigenfn for mode (s,q)
    !! glprefac: is the output in Ry units (EPW/QE)
    !
    ! This is similar to the subroutine dyn_nonanalytic above,
    ! adapted from ShengBTE's subroutine phonon_espresso.
    ! ShengBTE is distributed under GPL v3 or later.

    class(epw_wannier), intent(in) :: self
    type(crystal), intent(in) :: crys
    
    real(r64), intent(in) :: q(3) !Cartesian
    complex(r64), intent(in) :: uqs(self%numbranches)
    complex(r64), intent(out) :: glprefac

    real(r64) :: qeq, arg, zaq, g(3), gmax, alph, tpiba
    integer(i64) :: na,ipol, m1,m2,m3,nq1,nq2,nq3
    complex(r64) :: fac, facqd, facq

    tpiba = twopi/twonorm(crys%lattvecs(:,1))*bohr2nm

    !Recall that the phonon supercell in elphbolt is the
    !same as the EPW coarse phonon mesh.
    nq1 = self%coarse_qmesh(1)
    nq2 = self%coarse_qmesh(2)
    nq3 = self%coarse_qmesh(3)

    gmax= 14.d0 !dimensionless
    alph= tpiba**2 !bohr^-2
    !In Ry units, qe = sqrt(2.0) and epsilon_0 = 1/(4\pi)
    fac = 8.d0*pi/(crys%volume/bohr2nm**3)*oneI
    glprefac = (0.d0,0.d0)

    do m1 = -nq1,nq1
       do m2 = -nq2,nq2
          do m3 = -nq3,nq3
             g(:) = (m1*crys%reclattvecs(:,1)+m2*crys%reclattvecs(:,2)+m3*crys%reclattvecs(:,3))*bohr2nm + q
             qeq = dot_product(g,matmul(crys%epsilon,g))

             if (qeq > 0.d0 .and. qeq/alph/4.d0 < gmax ) then
                facqd = exp(-qeq/alph/4.0d0)/qeq

                do na = 1,crys%numatoms
                   arg = -dot_product(g,crys%basis_cart(:,na))/bohr2nm
                   facq = facqd*expi(arg)
                   do ipol=1,3
                      zaq = dot_product(g,crys%born(:,ipol,na))
                      glprefac = glprefac + facq*zaq*uqs(3*(na-1)+ipol)
                   end do
                end do
             end if
          end do
       end do
    end do
    glprefac = glprefac*fac
  end subroutine long_range_prefac

  subroutine gkRp_epw(self, num, ik, kvec)
    !! Calculate the Bloch-Wannier mixed rep. e-ph matrix elements g(k,Rp),
    !! where k is an IBZ electron wave vector and Rp is a phonon unit cell.
    !! Note: this step *DOES NOT* perform the rotation over the Wannier bands space.
    !!
    !! The result will be saved to disk tagged with k-index.

    class(epw_wannier), intent(in) :: self
    type(numerics), intent(in) :: num
    integer(i64), intent(in) :: ik
    real(r64), intent(in) :: kvec(3)

    !Local variables
    integer(i64) :: iuc
    complex(r64) :: caux
    complex(r64), allocatable:: gmixed(:,:,:,:)

    character(len = 1024) :: filename

    allocate(gmixed(self%numwannbands, self%numwannbands, self%numbranches, self%nwsq))

    !Fourier transform to k-space
    gmixed = 0
    do iuc = 1,self%nwsk
       caux = expi(twopi*dot_product(kvec, self%rcells_k(iuc,:)))/self%elwsdeg(iuc)
       gmixed(:,:,:,:) = gmixed(:,:,:,:) + caux*self%gwann(:,:,iuc,:,:)
    end do

    !Change to data output directory
    call chdir(trim(adjustl(num%g2dir)))

    !Write data in binary format
    !Note: this will overwrite existing data!
    write (filename, '(I9)') ik
    filename = 'gkRp.ik'//trim(adjustl(filename))
    open(1, file = trim(filename), status = 'replace', access = 'stream')
    write(1) gmixed
    close(1)

    !Change back to working directory
    call chdir(num%cwd)
  end subroutine gkRp_epw

  subroutine gReq_epw(self, num, iq, qvec)
    !! Calculate the Bloch-Wannier mixed rep. e-ph matrix elements g(Re,q),
    !! where q is an IBZ phonon wave vector and Re is a phonon unit cell.
    !! Note: this step *DOES NOT* perform the rotation over the Wannier bands space.
    !!
    !! The result will be saved to disk tagged with k-index.

    class(epw_wannier), intent(in) :: self
    type(numerics), intent(in) :: num
    integer(i64), intent(in) :: iq
    real(r64), intent(in) :: qvec(3)

    !Local variables
    integer(i64) :: iuc, s
    complex(r64) :: caux
    complex(r64), allocatable:: gmixed(:,:,:,:)

    character(len = 1024) :: filename

    allocate(gmixed(self%numwannbands, self%numwannbands, self%numbranches, self%nwsk))

    !Fourier transform to q-space
    gmixed = 0
    do iuc = 1,self%nwsg
       caux = expi(twopi*dot_product(qvec, self%rcells_g(iuc,:)))/self%gwsdeg(iuc)
       do s = 1, self%numbranches
          gmixed(:,:,s,:) = gmixed(:,:,s,:) + caux*self%gwann(:,:,:,s,iuc)
       end do
    end do

    !Change to data output directory
    call chdir(trim(adjustl(num%g2dir)))

    !Write data in binary format
    !Note: this will overwrite existing data!
    write (filename, '(I9)') iq
    filename = 'gReq.iq'//trim(adjustl(filename))
    open(1, file = trim(filename), status = 'replace', access = 'stream')
    write(1) gmixed
    close(1)

    !Change back to working directory
    call chdir(num%cwd)
  end subroutine gReq_epw

  subroutine deallocate_wannier(self, num)
    !! Deallocates some Wannier quantities

    class(epw_wannier), intent(inout) :: self
    type(numerics), intent(in) :: num
    
    deallocate(self%rcells_k, self%rcells_q, self%rcells_g, &
         self%elwsdeg, self%phwsdeg, self%gwsdeg, &
         self%Hwann, self%Dphwann)

    if(.not. num%read_gk2 .and. .not. num%read_gq2 .or. &
         num%plot_along_path) then
       deallocate(self%gwann)
    end if
  end subroutine deallocate_wannier
  
  subroutine plot_along_path(self, crys, num, scissor)
    !! Subroutine to plot bands, dispersions, e-ph matrix elements
    !! using the Wannier interpolation method with EPW inputs.

    class(epw_wannier), intent(in) :: self
    type(crystal), intent(in) :: crys
    type(numerics), intent(in) :: num
    real(r64), intent(in) :: scissor(self%numwannbands)

    !Local variables
    integer(i64) :: i, nqpath, m, n, s, deg_count, mp, np, sp, icart
    real(r64) :: k(1, 3), kp(1, 3), thres, aux, el_en, ph_en
    real(r64), allocatable :: qpathvecs(:,:), ph_ens_path(:,:), &
         el_ens_path(:,:), el_ens_kp(:,:), &
         el_vels_kp(:,:,:), g2_qpath(:,:,:,:), el_ens_k(:,:), el_vels_k(:,:,:)
    complex(r64), allocatable :: ph_evecs_path(:,:,:), el_evecs_kp(:,:,:), &
         el_evecs_k(:,:,:), gmixed_k(:,:,:,:) 
    character(len = 1024) :: filename
    character(len=8) :: saux

    call print_message("Plotting bands, dispersions, and e-ph vertex along path...")
    
    if(this_image() == 1) then

       !Threshold used to measure degeneracy
       thres = 1.0e-6_r64 !0.001 meV

       !Read list of wavevectors in crystal coordinates
       open(1, file = trim('highsympath.txt'), status = 'old')
       read(1,*) nqpath
       allocate(qpathvecs(nqpath, 3))
       do i = 1, nqpath
          read(1,*) qpathvecs(i,:)
       end do

       !Calculate phonon dispersions
       allocate(ph_ens_path(nqpath, self%numbranches), &
            ph_evecs_path(nqpath, self%numbranches, self%numbranches))
       call ph_wann_epw(self, crys, nqpath, qpathvecs, ph_ens_path, ph_evecs_path)

       !Output phonon dispersions
       write(saux, "(I0)") self%numbranches
       open(1, file = "ph.ens_qpath", status="replace")
       do i = 1, nqpath
          write(1,"("//trim(adjustl(saux))//"E20.10)") ph_ens_path(i,:)
       end do
       close(1)

       !Calculate electron bands
       allocate(el_ens_path(nqpath, self%numwannbands))
       call el_wann_epw(self, crys, nqpath, qpathvecs, el_ens_path, scissor = scissor)

       !Output electron dispersions
       write(saux,"(I0)") self%numwannbands
       open(1, file="el.ens_kpath",status="replace")
       do i = 1, nqpath
          write(1,"("//trim(adjustl(saux))//"E20.10)") el_ens_path(i,:)
       end do
       close(1)

       allocate(el_ens_k(1, self%numwannbands), el_vels_k(1, self%numwannbands, 3),&
            el_evecs_k(1, self%numwannbands, self%numwannbands))
       allocate(el_ens_kp(1, self%numwannbands), el_vels_kp(1, self%numwannbands, 3),&
            el_evecs_kp(1, self%numwannbands, self%numwannbands))
       allocate(g2_qpath(nqpath, self%numbranches, self%numwannbands, self%numwannbands))

       !Read wave vector of initial electron
       open(1, file = trim('initialk.txt'), status = 'old')
       read(1,*) k(1, :)

       !Calculate g(k, Rp)
       call self%gkRp_epw(num, 0_i64, k(1,:))

       !Load gmixed from file
       !Change to data output directory
       call chdir(trim(adjustl(num%g2dir)))
       allocate(gmixed_k(self%numwannbands, self%numwannbands, self%numbranches, self%nwsq))
       filename = 'gkRp.ik0'
       open(1, file = filename, status = "old", access = 'stream')
       read(1) gmixed_k
       close(1)
       !Change back to working directory
       call chdir(num%cwd)

       call el_wann_epw(self, crys, 1_i64, k, el_ens_k, el_vels_k, el_evecs_k, &
         scissor = scissor)

       do i = 1, nqpath !Over phonon wave vectors path
          kp(1, :) = k(1, :) + qpathvecs(i, :)
          do icart = 1, 3
             if(kp(1,icart) >= 1.0_r64) kp(1, icart) = kp(1, icart) - 1.0_r64
          end do

          !Calculate electrons at this final wave vector
          call el_wann_epw(self, crys, 1_i64, kp, el_ens_kp, el_vels_kp, el_evecs_kp, &
            scissor = scissor)

          do n = 1, self%numwannbands
             do m = 1, self%numwannbands
                do s = 1, self%numbranches
                   !Calculate |g(k,k')|^2
                   g2_qpath(i, s, m, n) = self%g2_epw(crys, k, qpathvecs(i, :), &
                        el_evecs_k(1, m, :), el_evecs_kp(1, n, :), ph_evecs_path(i, s, :), &
                        ph_ens_path(i, s), gmixed_k, 'ph')
                end do
             end do
          end do

          !The gauge arbitrariness of |g| due to the band and branch degeneraries
          !are removed below. The code below is closely following the change
          !to elphon.f90 of Quantum Espresso by C. Verdi and S. Ponce.
          !
          !This modified elphon.f90 was made available during EPW's 2018
          !ICTP/Psi-k/CECAM School on Electron-Phonon Physics from First Principles.
          !Visit for more info: https://docs.epw-code.org/doc/School2018.html
          
          !Average over degenerate phonon branches
          do m = 1, self%numwannbands
             do n = 1, self%numwannbands
                do s = 1, self%numbranches
                   deg_count = 0
                   aux = 0.0_r64
                   ph_en = ph_ens_path(i, s)
                   do sp = 1, self%numbranches
                      if(abs(ph_en - ph_ens_path(i, sp)) < thres) then
                         deg_count = deg_count + 1
                         aux = aux + g2_qpath(i, sp, m, n)
                      end if
                   end do
                   g2_qpath(i, s, m, n) = aux/dble(deg_count)
                end do
             end do
          end do

          !Average over initial electron bands
          do s = 1, self%numbranches
             do n = 1, self%numwannbands
                do m = 1, self%numwannbands
                   deg_count = 0
                   aux = 0.0_r64
                   el_en = el_ens_k(1, m)
                   do mp = 1, self%numwannbands
                      if(abs(el_en - el_ens_k(1, mp)) < thres) then
                         deg_count = deg_count + 1
                         aux = aux + g2_qpath(i, s, mp, n)
                      end if
                   end do
                   g2_qpath(i, s, m, n) = aux/dble(deg_count)
                end do
             end do
          end do

          !Average over final electron bands
          do s = 1, self%numbranches
             do m = 1, self%numwannbands
                do n = 1, self%numwannbands
                   deg_count = 0
                   aux = 0.0_r64
                   el_en = el_ens_kp(1, n)
                   do np = 1, self%numwannbands
                      if(abs(el_en - el_ens_kp(1, np)) < thres) then
                         deg_count = deg_count + 1
                         aux = aux + g2_qpath(i, s, m, np)
                      end if
                   end do
                   g2_qpath(i, s, m, n) = aux/dble(deg_count)
                end do
             end do
          end do
       end do

       !Print out |gk(m,n,s,qpath)|
       open(1, file = 'gk_qpath',status="replace")
       write(1,*) '   m    n    s    |gk|[eV]'
       do i = 1, nqpath
          do m = 1, self%numwannbands
             do n = 1, self%numwannbands
                do s = 1, self%numbranches
                   write(1,"(I5, I5, I5, E20.10)") m, n, s, sqrt(g2_qpath(i, s, m, n))
                end do
             end do
          end do
       end do   
       close(1)
    end if
    sync all
  end subroutine plot_along_path
end module wannier_module
