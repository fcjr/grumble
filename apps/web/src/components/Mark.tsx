export function Mark({ className }: { className?: string }) {
  return (
    <svg viewBox="240 330 540 380" className={className} aria-hidden="true">
      <path
        className="wave-draw"
        d="M280,412 q38.5,-100 77,0 q38.5,90 77,0 q38.5,-110 77,0 q38.5,100 77,0 q38.5,-80 77,0 q38.5,80 77,0"
        fill="none"
        stroke="#E8A33D"
        strokeWidth="46"
        strokeLinecap="round"
      />
      <path
        className="wave-draw wave-draw-2"
        d="M280,542 q38.5,-52 77,0 q38.5,48 77,0 q38.5,-56 77,0 q38.5,44 77,0"
        fill="none"
        stroke="#B98430"
        strokeWidth="46"
        strokeLinecap="round"
      />
      <path
        className="wave-draw wave-draw-3"
        d="M280,656 L616,656"
        fill="none"
        stroke="#EFE6D6"
        strokeWidth="46"
        strokeLinecap="round"
      />
      <circle className="dot-appear" cx="692" cy="656" r="27" fill="#D4553A" />
    </svg>
  );
}
