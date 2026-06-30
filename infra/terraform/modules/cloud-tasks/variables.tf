variable "project_id" {
  type = string
}

variable "env" {
  type = string
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "image_queue_concurrency" {
  description = "Max concurrent image generation jobs dispatched at once."
  type        = number
  default     = 20
}

variable "video_queue_concurrency" {
  description = "Max concurrent video generation jobs (each takes 2–10 min; keep low to avoid provider rate limits)."
  type        = number
  default     = 10
}

variable "merge_queue_concurrency" {
  description = "Max concurrent FFmpeg merge jobs (CPU-bound; keep low)."
  type        = number
  default     = 5
}
