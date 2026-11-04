// D2: dyld reserves this zero-fill segment before libc can allocate in the guest image range.
.zerofill __GUEST,__image,_ss_guest_image,0x1200000,14
