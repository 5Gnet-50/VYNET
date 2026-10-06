const PHONE_PATTERN = /^7\d{8}$/;

export function isValidPhone(phone: string): boolean {
  return PHONE_PATTERN.test(phone);
}

export function phoneToInternalAuthEmail(phone: string): string {
  if (!isValidPhone(phone)) {
    throw new Error("INVALID_PHONE");
  }

  return `${phone}@vynet.app`;
}

export function isValidPassword(password: string): boolean {
  return password.length >= 6;
}
